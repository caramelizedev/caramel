require "spec"
require "yaml"
require "../../scripts/checks/support/harness"
require "../../src/caramel/version"

describe "the release version" do
  it "is written once, in shard.yml, and carried by Caramel::VERSION and the built Latte.app" do
    version = YAML.parse(File.read(File.join(Caramel::Checks::REPO, "shard.yml")))["version"].as_s
    Caramel::VERSION.should eq(version)
    plist = File.join(Caramel::Checks::REPO, "bin/Latte.app/Contents/Info.plist")
    short_version = version.split('-').first
    %w[CFBundleShortVersionString CFBundleVersion].each do |key|
      extract = ["/usr/bin/plutil", "-extract", key, "raw", "-o", "-", plist]
      Caramel::Checks.run(extract, timeout: 10.seconds).stdout.strip.should eq(short_version)
    end
  end
end
