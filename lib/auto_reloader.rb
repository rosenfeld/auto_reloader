require 'auto_reloader/version'
require 'singleton'
require 'monitor'
require 'thread' # for Mutex
require 'set'
require 'time' unless defined?(Process::CLOCK_MONOTONIC)

class AutoReloader
  include Singleton

  attr_reader :reloadable_paths, :default_onchange, :default_delay

  module RequireOverride
    def require(path)
      AutoReloader.instance.require(path) { super }
    end

    def require_relative(path)
      fullpath = File.join File.dirname(caller.first), path
      AutoReloader.instance.require_relative path, fullpath
    end
  end

  def self.activate(*args)
    instance.activate *args
  end

  def initialize
    @activate_lock = Mutex.new
  end

  ActivatedMoreThanOnce = Class.new RuntimeError
  def activate(reloadable_paths: [], onchange: true, delay: nil)
    @activate_lock.synchronize do
      raise ActivatedMoreThanOnce, "Can only activate Autoreloader once" if @reloadable_paths
      @default_delay = delay
      @default_onchange = onchange
      self.reloadable_paths = reloadable_paths
      Object.include RequireOverride
      @require_lock = Monitor.new # monitor is like Mutex, but reentrant
      @reload_lock = Mutex.new
      @top_level_consts_stack = []
      @unload_constants = Set.new
      @unload_files = Set.new
      @last_reloaded = clock_time
    end
  end

  def self.reloadable_paths=(paths)
    instance.reloadable_paths = paths
  end

  def reloadable_paths=(paths)
    @reloadable_paths = paths.map{|rp| File.expand_path(rp).freeze }.freeze
  end

  def self.reloadable_paths
    instance.reloadable_paths
  end

  def require(path, &block)
    was_required = false
    @require_lock.synchronize do
      @top_level_consts_stack << Set.new
      old_consts = Object.constants
      prev_consts = new_top_level_constants = nil
      begin
        was_required = yield
      ensure
        prev_consts = @top_level_consts_stack.pop
        if was_required
          new_top_level_constants = Object.constants - old_consts - prev_consts.to_a
          @top_level_consts_stack.each{|c| c.merge new_top_level_constants }
        end
      end
      return false unless was_required # was required already, do nothing
      full_loaded_path = $LOADED_FEATURES.last
      reloadable = reloadable?(full_loaded_path, path)
      if reloadable
        @reload_lock.synchronize do
          @unload_constants.merge new_top_level_constants
          @unload_files << full_loaded_path
        end
      end
    end
    was_required
  end

  def require_relative(path, fullpath)
    Object.require fullpath
  end

  def self.reload!(delay: instance.default_delay, onchange: instance.default_onchange)
    if block_given?
      instance.reload!(delay: delay, onchange: onchange){ yield }
    else
      instance.reload!(delay: delay, onchange: onchange)
    end
  end

  InvalidUsage = Class.new RuntimeError
  def reload!(delay: default_delay, onchange: default_onchange)
    if onchange && !block_given?
      raise InvalidUsage, 'A block must be provided to reload! when onchange is true (the default)'
    end

    unload! unless reload_ignored = ignore_reload?(delay, onchange)

    result = nil
    if block_given?
      result = yield
      find_mtime
    end
    @last_reloaded = clock_time if delay
    result
  end

  def self.unload!
    instance.unload!
  end

  def unload!
    @reload_lock.synchronize do
      @unload_files.each{|f| $LOADED_FEATURES.delete f }
      @unload_constants.each{|c| Object.send :remove_const, c }
      @unload_files = Set.new
      @unload_constants = Set.new
    end
  end

  private

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

  def ignore_reload?(delay, onchange)
    (delay && (clock_time - @last_reloaded < delay)) || (onchange && !changed?)
  end

  def changed?
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
end
