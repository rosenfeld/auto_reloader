gem 'listen'

# we apply a monkey patch to rb-inotify to avoid polluting the logs until a new version is
# released from master:

begin
  require 'rb-inotify'

  class INotify::Event
    def callback!
      watcher && watcher.callback!(self)
    end
  end

  ::INotify::Notifier.prepend Module.new{
    def readpartial(size)
      return super unless self.class.supports_ruby_io?
      to_io.readpartial(size)
    rescue IOError, Errno::EBADF
    end
  }
rescue LoadError # ignore
end

require_relative '../lib/auto_reloader'

describe AutoReloader, order: :defined do
  fixture_lib_path = File.join __dir__, 'fixtures', 'lib'
  before(:all){
    load_once_path = File.join __dir__, 'fixtures', 'load_once'
    AutoReloader.activate onchange: false, reloadable_paths: [ fixture_lib_path ],
      watch_latency: 0.1
    $LOAD_PATH << fixture_lib_path << load_once_path
  }
  before(:each) do |example|
    AutoReloader.unload!
    AutoReloader.reloadable_paths = [fixture_lib_path]
  end
  after(:all) { AutoReloader.instance.stop_listener }
  
  it 'detects only constants defined in autoreloadable files' do
    expect(defined? ::Settings).to be nil
    expect(defined? ::C).to be nil
    require 'c'
    expect(defined? ::C).to eq 'constant'
    expect(defined? ::Settings).to eq 'constant'
    AutoReloader.unload!
    expect(defined? ::C).to be nil
    expect(defined? ::Settings).to eq 'constant'
  end

  it 'supports require_relative and recursive requires' do
    expect(defined? ::A).to be nil
    expect(defined? ::B).to be nil
    expect(defined? ::C).to be nil
    expect(defined? ::JSON).to be nil
    require 'a'
    expect(defined? ::A).to eq 'constant'
    expect(defined? ::B).to eq 'constant'
    expect(defined? ::C).to eq 'constant'
    expect(defined? ::JSON).to eq 'constant'
    AutoReloader.unload!
    expect(defined? ::A).to be nil
    expect(defined? ::B).to be nil
    expect(defined? ::C).to be nil
    expect(defined? ::JSON).to eq 'constant'
  end

  context 'with random order', order: :random do

    it 'reloads files upon reload! and accepts a block' do
      AutoReloader.reload! { require 'c' }
      expect(C.count).to be 1
      expect(C.count).to be 2
      AutoReloader.reload! { require 'c' }
      expect(C.count).to be 1
    end

    it 'raises on attempts to activate more than once' do
      expect{ AutoReloader.activate }.to raise_exception(AutoReloader::ActivatedMoreThanOnce)
    end

    it 'raises if onchange is specified and a block is not passed to reload!' do
      expect { AutoReloader.reload! onchange: true }.to raise_exception(AutoReloader::InvalidUsage)
    end

    it 'supports reloading only upon changing any of the loaded files' do
      require 'fileutils'

      AutoReloader.reload!(onchange: true){ require 'a' } # b and c are required as well
      expect(C.count).to be 1
      AutoReloader.reload!(onchange: true){ require 'a' }
      expect(C.count).to be 2 # C wasn't reloaded
      FileUtils.touch File.join __dir__, 'fixtures', 'lib', 'b.rb'
      if watch_paths?
        sleep RUBY_PLATFORM == 'java' ? 1 : 0.5 # wait for listen to detect the change
        AutoReloader.reload!(onchange: true){ require 'a' }
      else
        AutoReloader.reload!(onchange: true, watch_paths: false){ require 'a' }
      end
      expect(C.count).to be 1 # C was reloaded
    end

    # for some reason RSpec doesn't exit in Travis CI when enabling this example
    # even though it seems to work fine locally
    def watch_paths?
      return ENV['FORCE_WATCH'] == '1' if ENV.key?('FORCE_WATCH')
      #RUBY_PLATFORM != 'java'
      true
    end

    it 'supports forcing next reload' do
      AutoReloader.reload!(onchange: true){ require 'c' }
      expect(C.count).to be 1
      AutoReloader.reload!(onchange: true){ require 'c' }
      expect(C.count).to be 2
      AutoReloader.force_next_reload
      AutoReloader.reload!(onchange: true){ require 'c' }
      expect(C.count).to be 1
      AutoReloader.reload!(onchange: true){ require 'c' }
      expect(C.count).to be 2
    end

    it 'returns the block return value when passed to reload!' do
      expect(AutoReloader.reload!{ 'abc' }).to eq 'abc'
    end

    it 'supports a delay option' do
      AutoReloader.reload!(delay: 0.01){ require 'c' }
      expect(C.count).to be 1
      AutoReloader.reload!(delay: 0.01){ require 'c' }
      expect(C.count).to be 2
      sleep 0.01
      expect(C.count).to be 3
      AutoReloader.reload!(delay: 0.01){ require 'c' }
      expect(C.count).to be 1
    end

    context "changing reloadable paths" do
      around(:each) do |example|
        require 'tmpdir'
        Dir.mktmpdir do |dir|
          @dir = dir
          AutoReloader.reloadable_paths = [dir]
          $LOAD_PATH.unshift dir

          example.metadata[:tmpdir] = dir
          example.run

          $LOAD_PATH.shift
        end
      end

      example 'moving or removing a file should not raise while checking for change' do
        tmp_filename = File.join @dir, 'to_be_removed.rb'
        FileUtils.touch tmp_filename

        AutoReloader.reload!(onchange: true){ require 'to_be_removed' }
        File.delete tmp_filename
        expect { AutoReloader.reload!(onchange: true){} }.to_not raise_exception
      end
    end

    it 'respects default options passed to activate when calling reload!' do
      expect(AutoReloader.instance.default_onchange).to be false
    end

    # In case another reloader is in use or if the application itself removed it
    it 'does not raise if a reloadable constant has been already removed', focus: true do
      require 'c'
      Object.send :remove_const, 'C'
      expect(defined? ::C).to be nil
      expect{ AutoReloader.unload! }.to_not raise_exception
    end

  end # random order

  # this should run as the last one because it will load some files that won't be reloaded
  # due to the change in autoreloadable_paths
  context 'with restricted reloadable_paths' do
    before do
      AutoReloader.reloadable_paths = [File.join(__dir__, 'fixtures', 'lib', 'a')]
    end

    it 'respects reloadable_paths' do
      expect(defined? ::A::Inner).to be nil
      require 'a'
      expect(defined? ::A::Inner).to eq 'constant'
      AutoReloader.unload!
      expect(defined? ::A::Inner).to be nil
      # WARNING: one might expect A to remain defined since a.rb is not reloadable but it's
      # not possible to detect that automatically so this reloader is supposed to be used with
      # a sane files hierarchy.
      # Also, since it attempts to be fully transparent, we can't specify options to require
      # If there are any compelling real cases were this is causing troubles we may consider
      # providing a more specialized reloader to which some would specify which classes should
      # not be unloaded, for example. It could be extended through built-in modules for example.
      expect(defined? ::B).to eq 'constant'
    end
  end
end
