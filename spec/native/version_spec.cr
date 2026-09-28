require "spec"
require "yaml"
require "../../scripts/checks/support/harness"
require "../../src/caramel/version"

describe "the release version" do
  it "is written once, in shard.yml, and carried by Caramel::VERSION and the built Latte.app" do
    version = YAML.parse(File.read(File.join(Caramel::Checks::REPO, "shard.yml")))["version"].as_s
    Caramel::VERSION.should eq(version)
    plist = File.join(Caramel::Checks::REPO, "bin/Latte.app/Contents/Info.plist")
    %w[CFBundleShortVersionString CFBundleVersion].each do |key|
      Caramel::Checks.run(["/usr/bin/plutil", "-extract", key, "raw", "-o", "-", plist], timeout: 10.seconds).stdout.strip.should eq(version.split('-').first)
    end
  end
end
