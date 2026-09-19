require "spec"
require "file_utils"
require "../../src/latte/logs"

describe Caramel::Latte::Logs do
  it "retains a bounded tail while an existing service descriptor keeps writing" do
    root = File.join("/private/tmp", "latte-logs-#{Random::Secure.hex(6)}")
    paths = Caramel::Latte::Paths.new(root)
    begin
      path = File.join(paths.logs_dir, "proxy.log")
      File.open(path, "a", 0o600) do |writer|
        writer.sync = true
        writer << "a" * (Caramel::Latte::Logs::MAX_BYTES + 1)
        Caramel::Latte::Logs.sweep(paths)
        File.size(path).should eq(0)
        File.size(path + ".previous").should eq(Caramel::Latte::Logs::MAX_BYTES)
        File.info(path + ".previous").permissions.value.should eq(0o600)
        writer << "still writing\n"
        File.read(path).should eq("still writing\n")
      end
    ensure
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end
end
