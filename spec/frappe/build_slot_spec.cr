require "spec"
require "file_utils"
require "../../src/frappe/build_slot"

private FINGERPRINT = "a" * 64

private def with_project(&)
  root = File.tempname("caramel-build-slot-", dir: "/private/tmp")
  Dir.mkdir_p(File.join(root, ".caramel/dev"), 0o700)
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

# A finished build waiting to be installed: a binary and its debug file.
private def finished(root : String, content : String) : String
  temporary = File.join(root, ".caramel/dev/building")
  File.write(temporary, content)
  File.write(temporary + ".dwarf", "debug information for #{content}")
  temporary
end

describe Caramel::Frappe::BuildSlot do
  it "reuses a build only for its fingerprint, toolchain and mode, with its bytes intact" do
    with_project do |root|
      slot = Caramel::Frappe::BuildSlot.development(root, FINGERPRINT, "/toolchains/one")
      slot.install(finished(root, "first build"), FINGERPRINT)
      slot.holds?(FINGERPRINT).should be_true
      slot.holds?("b" * 64).should be_false
      other = Caramel::Frappe::BuildSlot.development(root, FINGERPRINT, "/toolchains/two")
      other.holds?(FINGERPRINT).should be_false
      record = File.join(root, ".caramel/dev/build.json")
      specs = Caramel::Frappe::BuildSlot.new(slot.binary, record, "/toolchains/one", "corretto")
      specs.holds?(FINGERPRINT).should be_false
      File.write(slot.binary, "a different binary")
      slot.holds?(FINGERPRINT).should be_false
    end
  end

  it "links a build into the command slot that outlives the original" do
    with_project do |root|
      development = Caramel::Frappe::BuildSlot.development(root, FINGERPRINT, "/toolchains/one")
      development.install(finished(root, "first build"), FINGERPRINT)
      command = Caramel::Frappe::BuildSlot.command(root, "/toolchains/one")
      command.link(development, FINGERPRINT)
      File.delete(development.binary)
      File.delete(development.binary + ".dwarf")
      command.holds?(FINGERPRINT).should be_true
      File.read(command.binary).should eq("first build")
    end
  end
end
