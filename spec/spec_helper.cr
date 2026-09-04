# spec/spec_helper.cr
require "spec"
require "file_utils"
require "random/secure"
require "../src/inotify"

# Creates a unique temporary directory, yields it, and removes it
# afterwards.
def mktmpdir(& : String ->)
  dir = File.join(Dir.tempdir, "inotify-spec-#{Process.pid}-#{Random::Secure.hex(6)}")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end
