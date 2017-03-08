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
    AutoReloader.reload! do |unloaded|
      # by default, AutoReloader only unloads constants when a watched file changes;
      # when it unloads code before calling this block, the value for unloaded will be true.
      ActiveSupport::Dependencies.clear if unloaded && defined?(ActiveSupport::Dependencies)
      require_relative 'app'
      App.call env
    end
  }
end
```

Just change "Sample output" to something else and reload the page.

By default reloading will only happen if one of the reloadable file was changed since it was
required. This can be overriden by providing the `onchange: false` option to either `activate`
or `reload!`. When the `listen` gem is available it's used by default to detect changes in
the `reloadable_paths` using specific OS watch mechanisms which allows AutoReloader to speed
up `reload!` when no changes happened although it won't probably do much difference unless
your application has tons of reloadable files loaded upon each request. If you don't want to
use `listen` when available, set `watch_paths: false` when calling `activate`.

Currently AutoReloader does not watch files other than those being required and I'm not sure
if it would be a good idea to provide this kind of feature through some option. However if
you want to force unloading the reloadable files when some configuration file (YAML, JSON, etc)
changes, it should be quite simple with the `listen` gem. Here's an example:

```ruby
app_config = File.expand_path('config/app.json', __dir__)
Listen.to(File.expand_path('config', __dir__)) do |added, modified, removed|
  AutoReloader.force_next_reload if (added + modified + removed).include?(app_config)
end
```

## Thread-safety

In order for the automatic constants and required files detection to work correctly it should
process a single require at a time. If your code has multiple threads requiring code, then it
might cause a race condition that could cause unexpected bugs to happen in AutoReloader. This
is the default behavior because it's not common to call require from multiple threads in the
development environment but adding a monitor around require could create a dead-lock which is
a more serious issue.

For example, if requiring a file would start a web server and block, if the web server is
started in a separate thread (which could be joined so that the require doesn't return), then
it wouldn't be able to require new files because the lock was acquired by another thread and
won't be released while the web server is running.

If you are sure that no require should block in your application (which is also common), you're
encouraged to call `AutoReloader.sync_require!`. Or pass `sync_require: true` to
`AutoReloader.activate`. You may even control this behavior dynamically so that you call
`AutoReloader.async_require!` before the blocking require and then reenable the sync behavior.
The sync behavior will ensure no race conditions that would break the automatic detection
mechanism would ever happen.

Also, it may be dangerous to unload classes while some requests are being processed. So, since
version 0.4, the default is to await for all blocks executed by `reload!` to finish running before
unloading. In case you prefer the old behavior because some requests may never return, which
could happen with some implementations of websocket connections handled by the same process
for example, just set the `await_before_unload` to `false` on `activate` or `reload!` calls.

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

