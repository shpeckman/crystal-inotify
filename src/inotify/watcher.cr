# src/inotify/watcher.cr
{% skip_file unless flag?(:linux) %}

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
  class Watcher
    @io            : IO::FileDescriptor
    @event_channel : Channel(Event)
    @enabled         = false
    @watch_list      = {} of Int32 => String
    @event_callbacks = [] of Proc(Event, Nil)

    # Creates a new inotify instance and starts reading from the event queue.
    #
    # If *recursive* is `true`, all existing subdirectories of a watched
    # directory are watched as well, and subdirectories created (or moved in)
    # later are watched automatically.
    def initialize(@recursive : Bool = false)
      fd = LibInotify.init(LibInotify::IN_NONBLOCK | LibInotify::IN_CLOEXEC)
      raise Error.from_errno("inotify_init1") if fd == -1
      @io = IO::FileDescriptor.new(fd)
      # Adopting the fd configures it as *blocking* (an inotify fd is an anon
      # inode, not a pipe/socket/character device). Switch it back to
      # non-blocking so that reads suspend the current fiber on the event
      # loop instead of blocking the whole thread.
      IO::FileDescriptor.set_blocking(fd, false)
      @event_channel = Channel(Event).new
      @enabled       = true
      spawn dispatch_events
      spawn read_events
    end

    # Reads raw event data from the inotify file descriptor. Suspends the
    # current fiber on the event loop until data is available.
    private def read_events : Nil
      buffer = Bytes.new(LibInotify::BUF_LEN)
      while @enabled
        bytes_read = @io.read(buffer)
        break if bytes_read <= 0
        parse_events(buffer[0, bytes_read])
      end
    rescue ex : IO::Error | Channel::ClosedError
      # A pending read or send gets interrupted when the watcher is closed.
      raise ex if @enabled
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
        event = Event.new(name, @watch_list[wd]?, mask, cookie, wd)
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
        @watch_list.delete(wd) if event.type.ignored?

        @event_channel.send(event)
        pos += LibInotify::EVENT_SIZE + len
      end
    end

    # Forwards events to all registered callbacks.
    private def dispatch_events : Nil
      while (event = @event_channel.receive?)
        @event_callbacks.each(&.call(event))
      end
    end

    # Registers a callback receiving all events.
    def on_event(&block : Event -> _) : Nil
      @event_callbacks << ->(event : Event) { block.call(event); nil }
    end

    # Removes all callbacks registered with `#on_event`.
    def clear_event_handlers : Nil
      @event_callbacks.clear
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
      @watch_list[wd] = path
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
      @watch_list.each do |wd, watched_path|
        return unwatch(wd) if watched_path == path
      end
      false
    end

    # Removes the watch with watch descriptor *wd*.
    # Returns `true` on success, otherwise raises `Inotify::Error`.
    def unwatch(wd : Int32) : Bool
      if LibInotify.rm_watch(@io.fd, wd) == -1
        raise Error.from_errno("inotify_rm_watch")
      end
      Log.debug { "unwatching wd=#{wd}" }
      @watch_list.delete(wd)
      true
    end

    # Returns all paths that are currently being watched.
    def watching : Array(String)
      @watch_list.values
    end

    # Returns `true` if the watcher is closed.
    def closed? : Bool
      @io.closed?
    end

    # Closes the inotify file descriptor and stops event delivery.
    def close : Nil
      return if closed?
      @enabled = false
      @io.close
      @event_channel.close
      Log.debug { "watcher closed" }
    end

    def finalize
      close
    end
  end
end
