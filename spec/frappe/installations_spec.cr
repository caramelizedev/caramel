require "spec"
require "file_utils"
require "../../src/frappe/installations"

describe Caramel::Frappe::Installations do
  it "registers, replaces and removes installation roots in a private registry" do
    root = "/private/tmp/caramel-installations-#{Random::Secure.hex(8)}"
    registry = Caramel::Frappe::Installations.new(root)
    registry.lookup("9.9.9").should be_nil
    File.exists?(root).should be_false
    registry.register("9.9.9", "/private/tmp/first").should be_nil
    registry.lookup("9.9.9").should eq("/private/tmp/first")
    registry.list.should eq({"9.9.9" => "/private/tmp/first"})
    registry.register("9.9.9", "/private/tmp/second").should eq("/private/tmp/first")
    registry.lookup("9.9.9").should eq("/private/tmp/second")
    File.info(File.join(root, "installations.json")).permissions.value.should eq(0o600)
    registry.remove("9.9.9").should be_true
    registry.remove("9.9.9").should be_false
    registry.list.should be_empty
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "rejects a group-readable installation registry" do
    root = "/private/tmp/caramel-installations-#{Random::Secure.hex(8)}"
    Dir.mkdir(root, 0o700)
    path = File.join(root, "installations.json")
    File.write(path, %({"version":1,"installations":{}}), perm: 0o640)
    expect_raises(Caramel::Frappe::Error, "must be a private owned file") do
      Caramel::Frappe::Installations.new(root).list
    end
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "names the newest registered release by semantic version" do
    root = "/private/tmp/caramel-installations-#{Random::Secure.hex(8)}"
    registry = Caramel::Frappe::Installations.new(root)
    registry.newest.should be_nil
    checkouts = {
      "0.9.0"       => "/a",
      "0.10.0-rc.1" => "/b",
      "0.10.0"      => "/c",
      "0.2.0"       => "/d",
    }
    checkouts.each { |release, checkout| registry.register(release, checkout) }
    registry.newest.should eq({"0.10.0", "/c"})
    registry.remove("0.10.0")
    registry.newest.should eq({"0.10.0-rc.1", "/b"})
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "refuses a registry written in a newer format and keeps it" do
    root = "/private/tmp/caramel-installations-#{Random::Secure.hex(8)}"
    Dir.mkdir(root, 0o700)
    path = File.join(root, "installations.json")
    original = %({"version":2,"installations":{"0.9.0":{"root":"/a","source":"tag"}}})
    File.write(path, original, perm: 0o600)
    expect_raises(Caramel::Frappe::Error, "written by a newer Caramel (format 2)") do
      Caramel::Frappe::Installations.new(root).register("0.1.0", "/b")
    end
    File.read(path).should eq(original)
  ensure
    FileUtils.rm_rf(root) if root
  end
end
