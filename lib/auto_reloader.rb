# frozen-string-literal: true

require 'auto_reloader/version'
require 'singleton'
require 'forwardable'
require 'monitor'
require 'thread' # for Mutex
require 'set'
require 'time' unless defined?(Process::CLOCK_MONOTONIC)

class AutoReloader
  include Singleton
  extend SingleForwardable

  # default_await_before_unload will await for all calls to reload! to finish before calling
  # unload!. This behavior is usually desired in web applications to avoid unloading anything
  # while a request hasn't been finished, however it won't work fine if some requests are
  # supposed to remain open, like websockets connections or something like that.

  attr_reader :reloadable_paths, :default_onchange, :default_delay, :default_await_before_unload

  def_delegators :instance, :activate, :reload!, :reloadable_paths, :reloadable_paths=,
    :unload!, :force_next_reload, :sync_require!, :async_require!

  module RequireOverride
    def require(path)
      AutoReloader.instance.require(path) { super }
    end

    def require_relative(path)
      from = caller.first.split(':', 2)[0]
      fullpath = File.expand_path File.join File.dirname(caller.first), path
      AutoReloader.instance.require_relative path, fullpath
    end
  end

  def initialize
    @activate_lock = Mutex.new
  end

  ActivatedMoreThanOnce = Class.new RuntimeError
  def activate(reloadable_paths: [], onchange: true, delay: nil, watch_paths: nil,
               watch_latency: 1, sync_require: false, await_before_unload: true)
    @activate_lock.synchronize do
      raise ActivatedMoreThanOnce, 'Can only activate Autoreloader once' if @reloadable_paths
      @default_delay = delay
      @default_onchange = onchange
      @default_await_before_unload = await_before_unload
      @watch_latency = watch_latency
      sync_require! if sync_require
      @reload_lock = Mutex.new
      @zero_requests_condition = ConditionVariable.new
      @requests_count = 0
      @top_level_consts_stack = []
      @unload_constants = Set.new
      @unload_files = Set.new
      @last_reloaded = clock_time
      try_listen unless watch_paths == false
      self.reloadable_paths = reloadable_paths
      Object.include RequireOverride
    end
  end

  # when concurrent threads require files race conditions may prevent the automatic detection
  # of constants created by a given file. Calling sync_require! will ensure only a single file
  # is required at a single time. However, if a required file blocks (think of a web server)
  # then any requires by a separate thread would be blocked forever (or until the web server
  # shutdowns). That's why require is async by default even though it would be vulnerable to
  # race conditions.
  def sync_require!
    @require_lock ||= Monitor.new # monitor is like Mutex, but reentrant
  end

  # See the documentation for sync_require! to understand the reasoning. Async require is the
  # default behavior but could lead to race conditions. If you know your requires will never
  # block it may be a good idea to call sync_require!. If you know what require will block you
  # can call async_require!, require it, and then call sync_require! which will generate a new
  # monitor.
  def async_require!
    @require_lock = nil
  end

  def reloadable_paths=(paths)
    @reloadable_paths = paths.map{|rp| File.expand_path(rp).freeze }.freeze
    setup_listener if @watch_paths
  end

  def require(path, &block)
    was_required = false
    error = nil
    maybe_synchronize do
      @top_level_consts_stack << Set.new
      old_consts = Object.constants
      prev_consts = new_top_level_constants = nil
      begin
        was_required = yield
      rescue Exception => e
        error = e
      ensure
        prev_consts = @top_level_consts_stack.pop
        return false if !error && !was_required # was required already, do nothing

        new_top_level_constants = Object.constants - old_consts - prev_consts.to_a

        (new_top_level_constants.each{|c| safe_remove_constant c }; raise error) if error

        @top_level_consts_stack.each{|c| c.merge new_top_level_constants }

        full_loaded_path = $LOADED_FEATURES.last
        return was_required unless reloadable? full_loaded_path, path
        @reload_lock.synchronize do
          @unload_constants.merge new_top_level_constants
          @unload_files << full_loaded_path
        end
      end
    end
    was_required
  end

  def maybe_synchronize(&block)
    @require_lock ? @require_lock.synchronize(&block) : yield
  end

  def require_relative(path, fullpath)
    require(fullpath){ Kernel.require fullpath }
  end

  InvalidUsage = Class.new RuntimeError
  def reload!(delay: default_delay, onchange: default_onchange, watch_paths: @watch_paths,
              await_before_unload: default_await_before_unload)
    if onchange && !block_given?
      raise InvalidUsage, 'A block must be provided to reload! when onchange is true (the default)'
    end

    unless reload_ignored = ignore_reload?(delay, onchange, watch_paths)
      @reload_lock.synchronize do
        @zero_requests_condition.wait(@reload_lock) unless @requests_count == 0
      end if await_before_unload && block_given?
      unload!
    end

    result = nil
    if block_given?
      @reload_lock.synchronize{ @requests_count += 1 }
      begin
        result = yield !reload_ignored
      ensure
        @reload_lock.synchronize{
          @requests_count -= 1
          @zero_requests_condition.signal if @requests_count == 0
        }
      end
      find_mtime
    end
    @last_reloaded = clock_time if delay
    result
  end

  def unload!
    @force_reload = false
    @reload_lock.synchronize do
      @unload_files.each{|f| $LOADED_FEATURES.delete f }
      @unload_constants.each{|c| safe_remove_constant c }
      @unload_files = Set.new
      @unload_constants = Set.new
    end
  end

  def stop_listener
    @listener.stop if @listener
  end

  def force_next_reload
    @force_reload = true
  end

  private

  def try_listen
    Kernel.require 'listen'
    @watch_paths = true
  rescue LoadError # ignore
    #puts 'listen is not available. Add it to Gemfile if you want to speed up change detection.'
  end

  def setup_listener
    @listener.stop if @listener
    @listener = Listen.to(*@reloadable_paths, latency: @watch_latency) do |m, a, r|
      @paths_changed = [m, a, r].any?{|o| o.any? {|f| reloadable?(f, nil) }}
    end
    @listener.start
  end

  if defined?(Process::CLOCK_MONOTONIC)
    def clock_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  else
    def clock_time
      Time.now.to_f
    end
  end

  def reloadable?(fullpath, path)
    @reloadable_paths.any?{|rp| fullpath.start_with? rp}
  end

  def ignore_reload?(delay, onchange, watch_paths = @watch_paths)
    return false if @force_reload
    (delay && (clock_time - @last_reloaded < delay)) || (onchange && !changed?(watch_paths))
  end

  def changed?(watch_paths = @watch_paths)
    return false if watch_paths && !@paths_changed
    @paths_changed = false
    return true unless @last_mtime_by_path
    @reload_lock.synchronize do
      return @unload_files.any?{|f| @last_mtime_by_path[f] != safe_mtime(f) }
    end
  end

  def safe_mtime(path)
    File.mtime(path) if File.exist?(path)
  end

  def find_mtime
    @reload_lock.synchronize do
      @last_mtime_by_path = {}
      @unload_files.each{|f| @last_mtime_by_path[f] = safe_mtime f }
    end
    @last_mtime_by_path
  end

  def safe_remove_constant(constant)
    Object.send :remove_const, constant
  rescue NameError # ignore if it has been already removed
  end
end
