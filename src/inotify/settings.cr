# src/inotify/settings.cr
{% skip_file unless flag?(:linux) %}

require "log"
require "./lib_inotify"

module Inotify
  # Logger for this shard, used with log source `"inotify"`.
  Log = ::Log.for("inotify")

  # Default set of events monitored by `Watcher#watch`.
  DEFAULT_WATCH_FLAG = LibInotify::IN_MOVE | LibInotify::IN_MOVE_SELF |
                       LibInotify::IN_MODIFY | LibInotify::IN_CREATE |
                       LibInotify::IN_DELETE | LibInotify::IN_DELETE_SELF
end
