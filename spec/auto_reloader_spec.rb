require_relative '../lib/auto_reloader'

describe AutoReloader do
  before(:all){
    fixture_lib_path = File.join __dir__, 'fixtures', 'lib'
    AutoReloader.activate onchange: false, reloadable_paths: [ fixture_lib_path ]
    $LOAD_PATH << fixture_lib_path
  }
  before(:each){ AutoReloader.unload! }
  
  it 'detects only constants defined in autoreloadable files' do
    expect(defined? ::DateTime).to be nil
    expect(defined? ::C).to be nil
    require 'c'
    expect(defined? ::C).to eq 'constant'
    expect(defined? ::DateTime).to eq 'constant'
    AutoReloader.unload!
    expect(defined? ::C).to be nil
    expect(defined? ::DateTime).to eq 'constant'
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
    AutoReloader.reload!(onchange: true){ require 'a' }
    expect(C.count).to be 1 # C was reloaded
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

  it 'respects reloadable_paths' do
    AutoReloader.reloadable_paths = [File.join(__dir__, 'fixtures', 'lib', 'a')]
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
