require "spec"
require "json"
require "file_utils"
require "../../src/latte/login_item"

describe Caramel::Latte::LoginItem do
  it "renders a LaunchAgent that starts the checkout's Latte at login and leaves its services alone" do
    directory = File.tempname("caramel-login-item-", dir: "/private/tmp")
    Dir.mkdir(directory, 0o700)
    begin
      latte = "/Users/bob/R&D <caramel>/bin/latte"
      item = Caramel::Latte::LoginItem.for_latte(latte)
      plist = File.join(directory, "agent.plist")
      File.write(plist, item.render)
      parsed = Process.run("/usr/bin/plutil", ["-convert", "json", "-o", "-", plist], output: :pipe) { |process| process.output.gets_to_end }
      agent = JSON.parse(parsed)
      agent["Label"].as_s.should eq("dev.caramel.latte")
      agent["ProgramArguments"].as_a.map(&.as_s).should eq([latte, "daemon", "--detach"])
      agent["RunAtLoad"].as_bool.should be_true
      agent["AbandonProcessGroup"].as_bool.should be_true
      agent.as_h.has_key?("KeepAlive").should be_false
      item.plist.should eq(File.join(Path.home.to_s, "Library/LaunchAgents/dev.caramel.latte.plist"))
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
