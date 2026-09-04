# examples/watch.cr
require "../src/inotify"

# Watches a path and prints every event.
#
#   crystal run examples/watch.cr -- /path/to/dir [--recursive] [--isolated]

recursive = !!ARGV.delete("--recursive")
isolated  = !!ARGV.delete("--isolated")
path      = ARGV.first? || abort("usage: watch [--recursive] [--isolated] PATH")

watcher = Inotify.watch(path, recursive: recursive, isolated: isolated) do |event|
  puts "#{event.type.to_s.ljust(12)} #{event.full_path}"
end

flags = [] of String
flags << "recursive" if recursive
flags << "isolated" if isolated
puts "Watching #{path}#{flags.empty? ? "" : " (#{flags})"} — Ctrl+C to stop"
sleep
