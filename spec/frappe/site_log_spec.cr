require "spec"
require "file_utils"
require "../../src/frappe/site_log"

describe Caramel::Frappe::SiteLog do
  it "appends bytes and retains them after closing" do
    root = "/private/tmp/caramel-site-log-#{Random::Secure.hex(8)}"
    Dir.mkdir(root, 0o700)
    path = File.join(root, "app.log")
    log = Caramel::Frappe::SiteLog.new(path, IO::Memory.new)
    log.write("first\n".to_slice)
    log.write("second\n".to_slice)
    log.close
    File.read(path).should eq("first\nsecond\n")
    File.info(path).permissions.value.should eq(0o600)
  ensure
    log.try(&.close)
    FileUtils.rm_rf(root) if root
  end

  it "rotates an oversized file and continues writing into a fresh log" do
    root = "/private/tmp/caramel-site-log-#{Random::Secure.hex(8)}"
    Dir.mkdir(root, 0o700)
    path = File.join(root, "compiler.log")
    log = Caramel::Frappe::SiteLog.new(path, IO::Memory.new)
    payload = "x" * (Caramel::Frappe::SiteLog::MAX_BYTES + 1)
    log.write(payload.to_slice)
    log.write("next\n".to_slice)
    log.close
    File.read(path + ".previous").should eq(payload)
    File.read(path).should eq("next\n")
  ensure
    log.try(&.close)
    FileUtils.rm_rf(root) if root
  end

  it "refuses a symlink instead of writing through it" do
    root = "/private/tmp/caramel-site-log-#{Random::Secure.hex(8)}"
    Dir.mkdir(root, 0o700)
    target = File.join(root, "target")
    path = File.join(root, "app.log")
    File.write(target, "untouched", perm: 0o600)
    File.symlink(target, path)
    expect_raises(Caramel::Frappe::Error, "Site log must be an owned private file") do
      Caramel::Frappe::SiteLog.new(path, IO::Memory.new)
    end
    File.read(target).should eq("untouched")
  ensure
    FileUtils.rm_rf(root) if root
  end
end
