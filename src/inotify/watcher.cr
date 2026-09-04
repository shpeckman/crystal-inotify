# src/inotify/watcher.cr
{% skip_file unless flag?(:linux) %}

require "sync"
require "./lib_inotify"
require "./settings"
require "./error"
require "./event"

module Inotify
  # Watches files and directories for filesystem events using Linux inotify.
  #
  # Events are read on a dedicated fiber that suspends on Crystal's event
  # loop while waiting for data (no busy polling), and are dispatched on a
  # second fiber to every callback registered through `#on_event`.
  #
  # ```
  # watcher = Inotify::Watcher.new(recursive: true)
  # watcher.on_event do |event|
  #   puts "#{event.type}: #{event.full_path}"
  # end
  # watcher.watch("/path/to/dir")
  # sleep 10.seconds
  # watcher.close
  # ```
  #
  # ### Concurrency
  #
  # All mutable state is protected by a `Sync::Mutex`, so every public
  # method is safe to call from fibers running in different — even
  # parallel — execution contexts. The callback list is copy-on-write:
  # event dispatch never holds the lock while running your callbacks.
  #
  # With `isolated: true` the event-reading fiber runs on a dedicated
  # `Fiber::ExecutionContext::Isolated` (its own system thread). This
  # guarantees the kernel event queue keeps being drained even when the
  # default execution context is busy with CPU-bound fibers that never
  # yield (protecting against `IN_Q_OVERFLOW`), at the cost of one OS
  # thread per watcher. Event callbacks still run on the execution
  # context that created the watcher.
  class Watcher
    @io            : IO::FileDescriptor
    @event_channel : Channel(Event)
    @enabled         = Atomic(Bool).new(false)
    @mutex           = Sync::Mutex.new
    @watch_list      = {} of Int32 => String
    @event_callbacks = [] of Proc(Event, Nil)

    # Creates a new inotify instance and starts reading from the event queue.
    #
    # If *recursive* is `true`, all existing subdirectories of a watched
    # directory are watched as well, and subdirectories created (or moved in)
    # later are watched automatically.
    #
    # If *isolated* is `true`, the event-reading fiber runs on a dedicated
    # `Fiber::ExecutionContext::Isolated` thread (see "Concurrency" above).
    def initialize(@recursive : Bool = false, *, isolated : Bool = false)
      fd = LibInotify.init(LibInotify::IN_NONBLOCK | LibInotify::IN_CLOEXEC)
      raise Error.from_errno("inotify_init1") if fd == -1
      @io = IO::FileDescriptor.new(fd)
      # Adopting the fd configures it as *blocking* (an inotify fd is an anon
      # inode, not a pipe/socket/character device). Switch it back to
      # non-blocking so that reads suspend the current fiber on the event
      # loop instead of blocking the whole thread.
      IO::FileDescriptor.set_blocking(fd, false)
      @event_channel = Channel(Event).new
      @enabled.set(true)
      if isolated
        Fiber::ExecutionContext::Isolated.new("inotify-watcher") { read_events }
      else
        spawn read_events
      end
      spawn dispatch_events
    end

    # Reads raw event data from the inotify file descriptor. Suspends the
    # current fiber on the event loop until data is available.
    private def read_events : Nil
      buffer = Bytes.new(LibInotify::BUF_LEN)
      while @enabled.get
        bytes_read = @io.read(buffer)
        break if bytes_read <= 0
        parse_events(buffer[0, bytes_read])
      end
    rescue ex : IO::Error | Channel::ClosedError
      # A pending read or send gets interrupted when the watcher is closed.
      raise ex if @enabled.get
    end

    # Splits raw event data into `Event`s and forwards them.
    private def parse_events(slice : Bytes) : Nil
      pos = 0
      while pos + LibInotify::EVENT_SIZE <= slice.size
        header = (slice.to_unsafe + pos).as(LibInotify::Event*)
        wd     = header.value.wd
        mask   = header.value.mask
        cookie = header.value.cookie
        len    = header.value.len.to_i32

        name  = len > 0 ? String.new((slice.to_unsafe + pos + LibInotify::EVENT_SIZE).as(LibC::Char*)) : nil
        path  = @mutex.synchronize { @watch_list[wd]? }
        event = Event.new(name, path, mask, cookie, wd)
        Log.debug { "received #{event}" }

        # Automatically watch new subdirectories.
        if @recursive && event.directory? && (event.type.create? || event.type.moved_to?) &&
           (dir_name = event.name) && (dir_path = event.path)
          begin
            watch(File.join(dir_path, dir_name))
          rescue ex : Inotify::Error | File::Error
            # The directory may already be gone again.
            Log.debug { "failed to watch new subdirectory: #{ex.message}" }
          end
        end

        # The watch was removed (explicitly, by deletion, or by unmount).
        @mutex.synchronize { @watch_list.delete(wd) } if event.type.ignored?

        @event_channel.send(event)
        pos += LibInotify::EVENT_SIZE + len
      end
    end

    # Forwards events to all registered callbacks. The callback list is
    # copy-on-write, so the lock is only taken to grab the reference and
    # is never held while running user code.
    private def dispatch_events : Nil
      while (event = @event_channel.receive?)
        callbacks = @mutex.synchronize { @event_callbacks }
        callbacks.each(&.call(event))
      end
    end

    # Registers a callback receiving all events.
    def on_event(&block : Event -> _) : Nil
      proc = ->(event : Event) { block.call(event); nil }
      @mutex.synchronize { @event_callbacks += [proc] }
    end

    # Removes all callbacks registered with `#on_event`.
    def clear_event_handlers : Nil
      @mutex.synchronize { @event_callbacks = [] of Proc(Event, Nil) }
    end

    # Adds a new watch, or modifies an existing watch, for *path*.
    #
    # *mask* determines which events are monitored (see the `LibInotify::IN_*`
    # constants); defaults to `DEFAULT_WATCH_FLAG`.
    # Returns the watch descriptor *wd*.
    def watch(path : String, mask : UInt32 = DEFAULT_WATCH_FLAG) : Int32
      wd = LibInotify.add_watch(@io.fd, path, mask)
      raise Error.from_errno("inotify_add_watch") if wd == -1
      Log.debug { "watching #{path} (wd=#{wd})" }
      @mutex.synchronize { @watch_list[wd] = path }
      if @recursive && File.directory?(path)
        Dir.each_child(path) do |child|
          child_path = File.join(path, child)
          watch(child_path, mask) if File.directory?(child_path)
        end
      end
      wd
    end

    # Removes the watch for *path*. Returns `true` on success.
    #
    # NOTE: *path* is case sensitive and has to exactly match the path
    # passed to `#watch`.
    def unwatch(path : String) : Bool
      wd = @mutex.synchronize do
        match = nil
        @watch_list.each do |watch_descriptor, watched_path|
          if watched_path == path
            match = watch_descriptor
            break
          end
        end
        match
      end
      return false unless wd
      unwatch(wd)
    end

    # Removes the watch with watch descriptor *wd*.
    # Returns `true` on success, otherwise raises `Inotify::Error`.
    def unwatch(wd : Int32) : Bool
      if LibInotify.rm_watch(@io.fd, wd) == -1
        raise Error.from_errno("inotify_rm_watch")
      end
      Log.debug { "unwatching wd=#{wd}" }
      @mutex.synchronize { @watch_list.delete(wd) }
      true
    end

    # Returns all paths that are currently being watched.
    def watching : Array(String)
      @mutex.synchronize { @watch_list.values }
    end

    # Returns `true` if the watcher is closed.
    def closed? : Bool
      @io.closed?
    end

    # Closes the inotify file descriptor and stops event delivery.
    def close : Nil
      return unless @enabled.swap(false)
      @io.close
      @event_channel.close
      Log.debug { "watcher closed" }
    end

    def finalize
      close
    end
  end
end
