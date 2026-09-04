# src/inotify/lib_inotify.cr
{% skip_file unless flag?(:linux) %}

# Raw bindings to the Linux inotify C API (`<sys/inotify.h>`).
lib LibInotify
  alias Uint32T = LibC::UInt

  # Flags for `inotify_init1`.
  IN_CLOEXEC  = LibC::O_CLOEXEC
  IN_NONBLOCK = LibC::O_NONBLOCK

  # Supported events suitable for the mask parameter of `inotify_add_watch`.
  IN_ACCESS        = 0x00000001_u32 # File was accessed.
  IN_MODIFY        = 0x00000002_u32 # File was modified.
  IN_ATTRIB        = 0x00000004_u32 # Metadata changed.
  IN_CLOSE_WRITE   = 0x00000008_u32 # Writable file was closed.
  IN_CLOSE_NOWRITE = 0x00000010_u32 # Unwritable file was closed.
  IN_OPEN          = 0x00000020_u32 # File was opened.
  IN_MOVED_FROM    = 0x00000040_u32 # File was moved from X.
  IN_MOVED_TO      = 0x00000080_u32 # File was moved to Y.
  IN_CREATE        = 0x00000100_u32 # Subfile was created.
  IN_DELETE        = 0x00000200_u32 # Subfile was deleted.
  IN_DELETE_SELF   = 0x00000400_u32 # Self was deleted.
  IN_MOVE_SELF     = 0x00000800_u32 # Self was moved.

  # Helper events.
  IN_CLOSE = LibInotify::IN_CLOSE_WRITE | LibInotify::IN_CLOSE_NOWRITE # Close (either kind).
  IN_MOVE  = LibInotify::IN_MOVED_FROM | LibInotify::IN_MOVED_TO       # Moves (either direction).

  # Events sent by the kernel.
  IN_UNMOUNT    = 0x00002000_u32 # Backing filesystem was unmounted.
  IN_Q_OVERFLOW = 0x00004000_u32 # Event queue overflowed.
  IN_IGNORED    = 0x00008000_u32 # Watch was removed.

  # Special flags.
  IN_ONLYDIR     = 0x01000000_u32 # Only watch the path if it is a directory.
  IN_DONT_FOLLOW = 0x02000000_u32 # Do not follow a symlink.
  IN_EXCL_UNLINK = 0x04000000_u32 # Exclude events on unlinked objects.
  IN_MASK_CREATE = 0x10000000_u32 # Only create a new watch, never update (Linux 4.18+).
  IN_MASK_ADD    = 0x20000000_u32 # Add to the mask of an already existing watch.
  IN_ISDIR       = 0x40000000_u32 # Event occurred against a directory.
  IN_ONESHOT     = 0x80000000_u32 # Only send event once.

  # All events which a program can wait on.
  IN_ALL_EVENTS = LibInotify::IN_ACCESS | LibInotify::IN_MODIFY | LibInotify::IN_ATTRIB |
                  LibInotify::IN_CLOSE_WRITE | LibInotify::IN_CLOSE_NOWRITE | LibInotify::IN_OPEN |
                  LibInotify::IN_MOVED_FROM | LibInotify::IN_MOVED_TO | LibInotify::IN_CREATE |
                  LibInotify::IN_DELETE | LibInotify::IN_DELETE_SELF | LibInotify::IN_MOVE_SELF

  # `struct inotify_event` from `<sys/inotify.h>`.
  #
  # The variable-length `name` field (a flexible array member) directly
  # follows this fixed header and is `len` bytes long, including NUL padding.
  struct Event
    wd     : LibC::Int
    mask   : Uint32T
    cookie : Uint32T
    len    : Uint32T
  end

  # Size of the fixed `inotify_event` header.
  EVENT_SIZE = sizeof(Event)

  # Read buffer: holds at least 1024 maximal events per `read(2)`.
  BUF_LEN = 1024 * (EVENT_SIZE + 16)

  fun init = inotify_init1(flags : LibC::Int) : LibC::Int
  fun add_watch = inotify_add_watch(fd : LibC::Int, name : LibC::Char*, mask : Uint32T) : LibC::Int
  fun rm_watch = inotify_rm_watch(fd : LibC::Int, wd : LibC::Int) : LibC::Int
end
