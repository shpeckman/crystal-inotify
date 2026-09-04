# inotify

Linux [inotify](https://man7.org/linux/man-pages/man7/inotify.7.html) bindings for the [Crystal](https://crystal-lang.org) programming language. Watch files and directories for filesystem events.

* Linux only (kernel ≥ 2.6.13; `IN_MASK_CREATE` needs ≥ 4.18)
* Crystal **≥ 1.21.0**
* Fiber-based: events are read on a dedicated fiber that suspends on Crystal's event loop — no busy polling, no extra threads
* API-compatible with [`petoem/inotify.cr`](https://github.com/petoem/inotify.cr)

## Installation

Add this to your application's `shard.yml`:

```yaml
dependencies:
  inotify:
    github: shpeckman/crystal-inotify
```

Then run:

```shell
shards install
```

## Usage

```crystal
require "crystal-inotify"

# To watch a file or directory ...
watcher = Inotify.watch "/path/to/file.txt" do |event|
  # your awesome logic
  puts "#{event.type}: #{event.full_path}"
end

# ... for 10 seconds.
sleep 10.seconds
watcher.close
```

> **Note:** You have to keep the main fiber busy (e.g. with `sleep`), or your program will exit.

### Watcher API

```crystal
watcher = Inotify::Watcher.new(recursive: true)

# Register any number of callbacks:
watcher.on_event { |event| puts "first handler: #{event}" }
watcher.on_event { |event| puts "second handler: #{event}" }

# Watch a path (recursively, since `recursive: true`):
watcher.watch("/path/to/dir")

# Watch with a custom event mask (see LibInotify::IN_* constants):
watcher.watch("/path/to/other", mask: LibInotify::IN_MODIFY | LibInotify::IN_CLOSE_WRITE)

watcher.watching          # => ["/path/to/dir", ...]
watcher.unwatch("/path/to/other") # => true
watcher.close
```

With `recursive: true`, all existing subdirectories are watched, and subdirectories created or moved in later are watched automatically.

### Events

Every `Inotify::Event` has:

| Method            | Type                   | Description                                                            |
|-------------------|------------------------|------------------------------------------------------------------------|
| `#type`           | `Inotify::Event::Type` | The event type (`CREATE`, `MODIFY`, `MOVED_FROM`, ...)                 |
| `#name`           | `String?`              | Name of the file inside the watched directory (`nil` for file watches) |
| `#path`           | `String?`              | The watched path the event occurred against                            |
| `#full_path`      | `String?`              | `path` joined with `name`                                              |
| `#mask`           | `UInt32`               | Raw event bitmask                                                      |
| `#cookie`         | `UInt32`               | Connects related events (`MOVED_FROM` ↔ `MOVED_TO`)                    |
| `#wd`             | `Int32`                | Watch descriptor                                                       |
| `#directory?`     | `Bool`                 | Whether the event occurred against a directory                         |
| `#type_is?(bits)` | `Bool`                 | Test raw `LibInotify::IN_*` bits against `#mask`                       |

The default mask is `Inotify::DEFAULT_WATCH_FLAG` (moves, modify, create, delete). Use `LibInotify::IN_ALL_EVENTS` to receive everything.

### Concurrency notes (Crystal ≥ 1.21)

Crystal 1.21 enables execution contexts by default, and this shard embraces them:

* **Thread-safe by `Sync`.** All mutable state of `Inotify::Watcher` is protected by a `Sync::Mutex`, so `watch`, `unwatch`, `watching`, `on_event`, `clear_event_handlers` and `close` are safe to call from fibers running in different — even parallel — execution contexts. The callback list is copy-on-write, so event dispatch never holds the lock while running your code (a callback can safely register more callbacks).
* **Optional isolated reader.** Pass `isolated: true` to run the event-reading fiber on a dedicated `Fiber::ExecutionContext::Isolated` (its own OS thread). The kernel event queue keeps being drained even when your default context is busy with CPU-bound fibers that never yield — protecting against `IN_Q_OVERFLOW` — at the cost of one thread per watcher. Events cross context boundaries through a context-safe `Channel`, and your callbacks still run on the execution context that created the watcher.

```crystal
watcher = Inotify.watch("/var/log", recursive: true, isolated: true) do |event|
  # runs on your default execution context
  puts event.full_path
end
```

### Example

A ready-to-run command line watcher is included:

```shell
crystal run examples/watch.cr -- /path/to/dir --recursive
```

## Development

```shell
crystal spec            # run the test suite
crystal tool format     # format sources
```

To enable debug logging, configure the `inotify` log source, e.g.:

```crystal
Log.setup("inotify", :debug)
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License

[MIT](LICENSE)
