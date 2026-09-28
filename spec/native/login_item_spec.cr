require "spec"
require "../../scripts/checks/support/harness"
require "../../src/latte/login_item"

describe "Latte login item" do
  it "runs at load, leaves the job's children running when it ends, and uninstalls cleanly" do
    directory = Caramel::Checks.private_temp("caramel-login-item-native-")
    label = "dev.caramel.latte.check.#{Random::Secure.hex(6)}"
    ran = File.join(directory, "ran")
    child = File.join(directory, "child")
    # Stands in for the daemon: starts a long-lived child in its process
    # group, as the daemon starts services, then exits.
    script = "/bin/sleep 120 & echo $! > '#{child}'; echo $$ > '#{ran}'"
    item = Caramel::Latte::LoginItem.new(["/bin/sh", "-c", script], label, directory)
    survivor = nil
    begin
      item.install
      Caramel::Checks.wait_until(10.seconds, 50.milliseconds) { File.exists?(ran) && File.exists?(child) }.should be_true
      survivor = File.read(child).strip.to_i64
      # The job itself exits right away; launchd must not take the child with it.
      Caramel::Checks.wait_until(5.seconds, 50.milliseconds) { !Process.exists?(File.read(ran).strip.to_i64) }.should be_true
      sleep 500.milliseconds
      Process.exists?(survivor).should be_true
      item.uninstall.should be_true
      File.exists?(item.plist).should be_false
      Caramel::Checks.run(["/bin/launchctl", "print", "#{item.domain}/#{label}"], timeout: 10.seconds).success?.should be_false
      Process.exists?(survivor).should be_true
      item.uninstall.should be_false
    ensure
      item.uninstall
      survivor.try { |pid| Process.signal(Signal::KILL, pid) if Process.exists?(pid) }
      FileUtils.rm_rf(directory)
    end
  end
end
