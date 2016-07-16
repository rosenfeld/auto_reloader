# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'auto_reloader/version'

Gem::Specification.new do |spec|
  spec.name          = 'auto_reloader'
  spec.version       = AutoReloader::VERSION
  spec.authors       = ['Rodrigo Rosenfeld Rosas']
  spec.email         = ['rr.rosas@gmail.com']

  spec.summary       = %q{A transparent code reloader.}
  spec.homepage      = 'https://github.com/rosenfeld/auto_reloader'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^spec/}) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.11'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
end
