# src/inotify/event.cr
{% skip_file unless flag?(:linux) %}

require "./lib_inotify"

module Inotify
  # Represents an `inotify_event` structure.
  struct Event
    # Name of the file or directory that triggered the event.
    # Always `nil` if `#wd` is associated with a file.
    property name : String?

    # Watched path this event occurred against.
    # May be `nil` if the associated watch is unknown.
    property path : String?

    # Contains bits that describe the event that occurred.
    property mask : UInt32

    # Unique integer that connects related events
    # (e.g. `MOVED_FROM` and `MOVED_TO` of the same rename).
    property cookie : UInt32

    # Watch descriptor identifying the watch this event occurred for.
    getter wd : Int32

    # The `Type` of the event.
    getter type : Type

    # Creates a new event.
    def initialize(@name : String?, @path : String?, @mask : UInt32, @cookie : UInt32, @wd : Int32)
      @type = Type.parse(@mask)
    end

    # Returns `true` if the event occurred against a directory.
    def directory? : Bool
      type_is?(LibInotify::IN_ISDIR)
    end

    # Returns whether the given *bits* are set in `#mask`.
    # Useful when `#type` is `Type::UNKNOWN`.
    def type_is?(bits : UInt32) : Bool
      bits & @mask != 0
    end

    # Returns the full path of the file or directory that triggered the
    # event, i.e. `#path` joined with `#name`. Falls back to `#path` when
    # the event has no name (watch on a single file).
    def full_path : String?
      if (path = @path) && (name = @name)
        File.join(path, name)
      else
        @path
      end
    end

    def to_s(io : IO) : Nil
      io << @type
      io << ' ' << full_path
      io << " (wd=" << @wd
      io << ", cookie=" << @cookie unless @cookie.zero?
      io << ')'
    end

    # Event types corresponding to the ones in `LibInotify`.
    enum Type : UInt32
      UNKNOWN       = 0x00000000
      ACCESS        = LibInotify::IN_ACCESS
      MODIFY        = LibInotify::IN_MODIFY
      ATTRIB        = LibInotify::IN_ATTRIB
      CLOSE_WRITE   = LibInotify::IN_CLOSE_WRITE
      CLOSE_NOWRITE = LibInotify::IN_CLOSE_NOWRITE
      OPEN          = LibInotify::IN_OPEN
      MOVED_FROM    = LibInotify::IN_MOVED_FROM
      MOVED_TO      = LibInotify::IN_MOVED_TO
      CREATE        = LibInotify::IN_CREATE
      DELETE        = LibInotify::IN_DELETE
      DELETE_SELF   = LibInotify::IN_DELETE_SELF
      MOVE_SELF     = LibInotify::IN_MOVE_SELF
      CLOSE         = LibInotify::IN_CLOSE
      MOVE          = LibInotify::IN_MOVE
      UNMOUNT       = LibInotify::IN_UNMOUNT
      Q_OVERFLOW    = LibInotify::IN_Q_OVERFLOW
      IGNORED       = LibInotify::IN_IGNORED

      # Parses the given *mask* and returns the event type or `UNKNOWN`.
      def self.parse(mask : UInt32) : self
        each do |member, bits|
          return member if bits & mask != 0
        end
        UNKNOWN
      end
    end
  end
end
