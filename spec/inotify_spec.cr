# spec/inotify_spec.cr
require "./spec_helper"

# Waits for the first event matching the given predicate, skipping any
# unrelated events. Raises if no matching event arrives within *timeout*.
def next_event(events : Channel(Inotify::Event), timeout : Time::Span = 5.seconds, & : Inotify::Event -> Bool) : Inotify::Event
  deadline = Time.instant + timeout
  loop do
    remaining = deadline - Time.instant
    raise "timed out waiting for matching inotify event" if remaining <= Time::Span.zero
    select
    when event = events.receive
      return event if yield event
    when timeout(remaining)
      raise "timed out waiting for matching inotify event"
    end
  end
end

describe Inotify do
  it "detects file creation in a watched directory" do
    mktmpdir do |dir|
      events  = Channel(Inotify::Event).new
      watcher = Inotify.watch(dir) { |event| events.send(event) }
      File.touch(File.join(dir, "created.txt"))

      event = next_event(events, &.type.create?)
      event.name.should eq "created.txt"
      event.path.should eq dir
      event.full_path.should eq File.join(dir, "created.txt")
      event.directory?.should be_false
      event.wd.should be >= 0
    ensure
      watcher.try &.close
    end
  end

  it "detects file modification" do
    mktmpdir do |dir|
      path = File.join(dir, "file.txt")
      File.touch(path)
      events  = Channel(Inotify::Event).new
      watcher = Inotify.watch(dir) { |event| events.send(event) }
      File.write(path, "hello")

      event = next_event(events, &.type.modify?)
      event.name.should eq "file.txt"
      event.path.should eq dir
    ensure
      watcher.try &.close
    end
  end

  it "detects file deletion" do
    mktmpdir do |dir|
      path = File.join(dir, "doomed.txt")
      File.touch(path)
      events  = Channel(Inotify::Event).new
      watcher = Inotify.watch(dir) { |event| events.send(event) }
      File.delete(path)

      event = next_event(events, &.type.delete?)
      event.name.should eq "doomed.txt"
    ensure
      watcher.try &.close
    end
  end

  it "pairs MOVED_FROM and MOVED_TO with the same cookie" do
    mktmpdir do |dir|
      old_path = File.join(dir, "old.txt")
      new_path = File.join(dir, "new.txt")
      File.touch(old_path)
      events  = Channel(Inotify::Event).new
      watcher = Inotify.watch(dir) { |event| events.send(event) }
      File.rename(old_path, new_path)

      from = next_event(events, &.type.moved_from?)
      to   = next_event(events, &.type.moved_to?)
      from.name.should eq "old.txt"
      to.name.should eq "new.txt"
      from.cookie.should_not eq 0
      to.cookie.should eq from.cookie
    ensure
      watcher.try &.close
    end
  end

  it "watches a single file" do
    mktmpdir do |dir|
      path = File.join(dir, "watched.txt")
      File.write(path, "initial")
      events  = Channel(Inotify::Event).new
      watcher = Inotify.watch(path) { |event| events.send(event) }
      File.write(path, "changed")

      event = next_event(events, &.type.modify?)
      event.name.should be_nil
      event.path.should eq path
      event.full_path.should eq path
    ensure
      watcher.try &.close
    end
  end

  it "watches subdirectories recursively, including new ones" do
    mktmpdir do |dir|
      existing = File.join(dir, "existing")
      Dir.mkdir(existing)
      events  = Channel(Inotify::Event).new
      watcher = Inotify.watch(dir, recursive: true) { |event| events.send(event) }
      watcher.watching.should contain(existing)

      # New subdirectory gets watched automatically.
      subdir = File.join(dir, "sub")
      Dir.mkdir(subdir)
      created = next_event(events) { |event| event.type.create? && event.directory? }
      created.name.should eq "sub"

      File.touch(File.join(subdir, "nested.txt"))
      nested = next_event(events) { |event| event.type.create? && event.name == "nested.txt" }
      nested.path.should eq subdir
      nested.full_path.should eq File.join(subdir, "nested.txt")
    ensure
      watcher.try &.close
    end
  end

  it "adds and removes watches" do
    mktmpdir do |dir|
      watcher = Inotify.watcher
      wd      = watcher.watch(dir)
      wd.should be >= 0
      watcher.watching.should eq [dir]

      watcher.unwatch(dir).should be_true
      watcher.watching.should be_empty
      watcher.unwatch(dir).should be_false
    ensure
      watcher.try &.close
    end
  end

  it "supports multiple event callbacks" do
    mktmpdir do |dir|
      first   = Channel(Inotify::Event).new
      second  = Channel(Inotify::Event).new
      watcher = Inotify.watcher
      watcher.on_event { |event| first.send(event) }
      watcher.on_event { |event| second.send(event) }
      watcher.watch(dir)
      File.touch(File.join(dir, "multi.txt"))

      next_event(first, &.type.create?).name.should eq "multi.txt"
      next_event(second, &.type.create?).name.should eq "multi.txt"
    ensure
      watcher.try &.close
    end
  end

  it "can be closed twice" do
    watcher = Inotify.watcher
    watcher.close
    watcher.closed?.should be_true
    watcher.close
    watcher.closed?.should be_true
  end

  it "reads events on an isolated execution context" do
    mktmpdir do |dir|
      events  = Channel(Inotify::Event).new
      watcher = Inotify.watch(dir, isolated: true) { |event| events.send(event) }
      File.touch(File.join(dir, "isolated.txt"))

      event = next_event(events, &.type.create?)
      event.name.should eq "isolated.txt"
      event.path.should eq dir
    ensure
      watcher.try &.close
    end
  end

  it "closes cleanly while an isolated reader is blocked on read" do
    watcher = Inotify.watcher(isolated: true)
    mktmpdir do |dir|
      watcher.watch(dir)
      sleep 100.milliseconds # let the reader block on read
      watcher.close
      watcher.closed?.should be_true
    end
  end

  it "supports concurrent watch/unwatch from parallel contexts" do
    mktmpdir do |dir|
      events  = Channel(Inotify::Event).new(512)
      watcher = Inotify.watch(dir) { |event| events.send(event) }
      done    = Channel(Nil).new

      2.times do |i|
        Fiber::ExecutionContext::Isolated.new("inotify-spec-stress") do
          30.times do |j|
            sub = File.join(dir, "stress-#{i}-#{j}")
            Dir.mkdir(sub)
            watcher.watch(sub)
            watcher.on_event { |_| } if j % 15 == 0
            watcher.watching
            watcher.unwatch(sub)
          end
          done.send(nil)
        end
      end

      2.times do
        select
        when done.receive
        when timeout(15.seconds)
          raise "timed out waiting for stress fibers"
        end
      end

      # The watcher is still functional afterwards.
      File.touch(File.join(dir, "after.txt"))
      event = next_event(events) { |e| e.type.create? && e.name == "after.txt" }
      event.path.should eq dir
    ensure
      watcher.try &.close
    end
  end

  describe Inotify::Event::Type do
    it "parses masks" do
      Inotify::Event::Type.parse(LibInotify::IN_CREATE | LibInotify::IN_ISDIR).should eq Inotify::Event::Type::CREATE
      Inotify::Event::Type.parse(LibInotify::IN_CLOSE_WRITE).should eq Inotify::Event::Type::CLOSE_WRITE
      Inotify::Event::Type.parse(0_u32).should eq Inotify::Event::Type::UNKNOWN
    end
  end
end
