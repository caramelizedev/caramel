require "spec"
require "file_utils"
require "system/user"
require "../../../src/caramel"

private GID = System::User.find_by(id: LibC.getuid.to_s).group_id.to_i

# Runs the block with a directory of *mode* whose group is this process's; a new
# directory inherits its parent's group on macOS.
private def with_directory(mode : Int32, &)
  directory = "/private/tmp/caramel-runtime-#{Random::Secure.hex(6)}"
  Dir.mkdir(directory)
  File.chmod(directory, mode)
  File.chown(directory, gid: GID)
  yield directory
ensure
  FileUtils.rm_rf(directory) if directory
end

describe Caramel::Crema do
  describe ".group_directory?" do
    it "accepts a directory the group may enter but not write" do
      with_directory(0o750) { |dir| Caramel::Crema.group_directory?(dir, GID).should be_true }
      with_directory(0o710) { |dir| Caramel::Crema.group_directory?(dir, GID).should be_true }
    end

    it "rejects group write, any access for others, another group and a file" do
      with_directory(0o770) { |dir| Caramel::Crema.group_directory?(dir, GID).should be_false }
      with_directory(0o751) { |dir| Caramel::Crema.group_directory?(dir, GID).should be_false }
      with_directory(0o750) { |dir| Caramel::Crema.group_directory?(dir, GID + 1).should be_false }
      with_directory(0o750) do |dir|
        file = File.join(dir, "file")
        File.write(file, "")
        File.chmod(file, 0o750)
        Caramel::Crema.group_directory?(file, GID).should be_false
      end
    end
  end

  describe ".private_directory?" do
    it "accepts only a directory its owner alone can reach" do
      with_directory(0o700) { |dir| Caramel::Crema.private_directory?(dir).should be_true }
      with_directory(0o750) { |dir| Caramel::Crema.private_directory?(dir).should be_false }
    end
  end
end
