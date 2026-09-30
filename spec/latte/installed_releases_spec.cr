require "spec"
require "file_utils"
require "../../src/latte/installed_releases"
require "../../src/latte/config_file"

private def write_installations(state : String, entries : Hash(String, String)) : Nil
  document = {version: 1, installations: entries}.to_json
  Caramel::Latte::ConfigFile.write(Caramel::Latte::InstalledReleases.path(state), document)
end

describe Caramel::Latte::InstalledReleases do
  it "runs a newer installed release's built latte, and otherwise this release's own" do
    state = "/private/tmp/caramel-installed-#{Random::Secure.hex(8)}"
    Dir.mkdir(state, 0o700)
    newer = File.join(state, "releases/9.9.9")
    built = File.join(newer, "bin/latte")
    begin
      Caramel::Latte::InstalledReleases.newer_latte(state, "0.1.0").should be_nil
      write_installations(state, {"0.1.0" => "/private/tmp/own", "9.9.9" => newer})
      # Not built yet: this release's own latte serves.
      Caramel::Latte::InstalledReleases.newer_latte(state, "0.1.0").should be_nil
      Dir.mkdir_p(File.join(newer, "bin"))
      File.write(built, "#!/bin/sh\n")
      File.chmod(built, 0o755)
      Caramel::Latte::InstalledReleases.newer_latte(state, "0.1.0").should eq(built)
      Caramel::Latte::InstalledReleases.newer_latte(state, "10.0.0").should be_nil
    ensure
      FileUtils.rm_rf(state)
    end
  end
end
