# src/inotify/error.cr
{% skip_file unless flag?(:linux) %}

module Inotify
  # Raised when an underlying inotify syscall fails.
  class Error < Exception
    include SystemError
  end
end
