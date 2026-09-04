# examples/watch.cr
require "../src/inotify"

# Watches a path and prints every event.
#
#   crystal run examples/watch.cr -- /path/to/dir [--recursive]

recursive = !!ARGV.delete("--recursive")
path      = ARGV.first? || abort("usage: watch [--recursive] PATH")

watcher = Inotify.watch(path, recursive: recursive) do |event|
  puts "#{event.type.to_s.ljust(12)} #{event.full_path}"
end

puts "Watching #{path}#{recursive ? " (recursive)" : ""} — Ctrl+C to stop"
sleep
