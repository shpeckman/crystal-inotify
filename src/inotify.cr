# src/inotify.cr
require "./inotify/version"

{% skip_file unless flag?(:linux) %}

require "./inotify/lib_inotify"
require "./inotify/settings"
require "./inotify/error"
require "./inotify/event"
require "./inotify/watcher"

# `Inotify` provides bindings to the Linux inotify API for watching files
# and directories for filesystem events.
module Inotify
  # Same as `Inotify::Watcher.new`.
  def self.watcher(recursive : Bool = false) : Inotify::Watcher
    Watcher.new(recursive)
  end

  # All-in-one method to create an inotify instance watching one *path*.
  #
  # ```
  # require "inotify"
  #
  # # To watch a file or directory ...
  # watcher = Inotify.watch("/path/to/file.txt") do |event|
  #   # your awesome logic
  # end
  #
  # # ... for 10 seconds.
  # sleep 10.seconds
  # watcher.close
  # ```
  #
  # NOTE: You have to keep the main fiber busy (e.g. with `sleep`), or the
  # program will exit.
  def self.watch(path : String, recursive : Bool = false, &block : Inotify::Event -> _) : Inotify::Watcher
    inotify = Inotify.watcher(recursive)
    inotify.on_event(&block)
    inotify.watch(path)
    inotify
  end
end
