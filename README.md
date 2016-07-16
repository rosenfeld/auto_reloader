# AutoReloader [![Build Status](https://travis-ci.org/rosenfeld/auto_reloader.svg?branch=master)](https://travis-ci.org/rosenfeld/auto_reloader)

AutoReloader is a lightweight code reloader intended to be used specially in development mode of server applications.

It will override `require` and `require_relative` when activated.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'auto_reloader'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install auto_reloader

## Usage

AutoReloader will try to add auto-reloading code support transparently by unloading all files
belonging to the list of reloadable paths and the constants defined by them. This is not always
possible to handle transparently, so please read the Known Caveats to properly understand what
you should do to avoid them.

Here's how it would be used in a Rack application.

app.rb:

```ruby
App = ->{['200', {'Content-Type' => 'text/plain'}, ['Sample output']]}
```

config.ru:

```ruby
if ENV['RACK_ENV'] != 'development'
  require_relative 'app'
  run App
else
  require 'auto_reloader'
  # won't reload before 1s elapsed since last reload by default. It can be overridden
  # in the reload! call below
  AutoReloader.activate reloadable_paths: [__dir__], delay: 1
  run ->(env) {
    AutoReloader.reload! do
      require_relative 'app'
      App.call env
    end
  }
end
```

Just change "Sample output" to something else and reload the page.

By default reloading will only happen if one of the reloadable file was changed since it was
required. This can be overriden by providing the `onchange: false` option to either `activate`
or `reload!`.

## Known Caveats

In order to work transparently AutoReloader will override `require` and `require_relative` when
activated and track changes to the top-level constants after each require. Top-level constants
defined by reloadable files are removed upon `reload!` or `unload!`. So, if your application
does something crazy like this:

json-extension.rb:

```ruby
class JSON
  class MyExtension
  # crazy stuff: don't do that
  end
end
```

If you require 'json-extension' before requiring 'json', supposing it's reloadable, `unload!`
and `reload!` would remove the JSON constant because AutoReloader will think it was defined
by 'json-extension'. If you require 'json' before this file, then JSON won't be removed but
neither will JSON::MyExtension.

As a general rule, any reloadable file should not change the behavior of code in non
reloadable files.

## Implementation description

AutoReloader doesn't try to reload only the changed files. If any of the reloadable files change
then all reloadable files are unloaded and the constants they defined are removed. Reloadable
files are those living in one of the `reloadable_paths` entries. The more paths it has to search
the bigger will be the overhead to `require` and `require_relative`.

Currently this implementation does not use an evented watcher to detect changes to files but
it may be considered in future versions. Currently it traverses each loaded reloadable file and
check whether it was changed.

## AutoReloadable does not support automatic autoload

AutoReloadable does not provide automatic autoload features like ActiveSupport::Dependencies
by design and won't support it ever, although such feature could be implemented as an extension
or as a separate gem. Personally I don't find it a good practice and I think all dependencies
should be declared explicitly by all files depending on them even if it's not necessary because
it was already required by another file.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec`
to run the tests. You can also run `bin/console` for an interactive prompt that will allow
you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a
new version, update the version number in `version.rb`, and then run `bundle exec rake release`,
which will create a git tag for the version, push git commits and tags, and push the `.gem`
file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome
[on GitHub](https://github.com/rosenfeld/auto_reloader).


## License

The gem is available as open source under the terms of the
[MIT License](http://opensource.org/licenses/MIT).

