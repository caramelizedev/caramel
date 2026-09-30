require "spec"
require "../../scripts/checks/support/harness"

INTEGRATION_BINARY      = File.join(Caramel::Checks::REPO, "bin/install-local-integration")
INTEGRATION_TEST_BINARY = File.join(Caramel::Checks::REPO, "bin/test/install-local-integration")
unless File.file?(INTEGRATION_BINARY) && File.file?(INTEGRATION_TEST_BINARY)
  raise "Run scripts/check native"
end

private class IntegrationFixture
  getter root : String
  getter bundle : String
  getter system_root : String
  getter destinations : Hash(String, String)
  getter receipt : String
  getter log : String

  def initialize
    @root = Caramel::Checks.private_temp("Toolchain With Spaces-local-integration-")
    @bundle = File.join(@root, "bundle")
    @system_root = File.join(@root, "system")
    Dir.mkdir(@system_root, 0o700)
    @destinations = {
      "relay"    => File.join(@system_root, "helper", "dev.caramel.ports"),
      "plist"    => File.join(@system_root, "launchd", "dev.caramel.ports.plist"),
      "resolver" => File.join(@system_root, "resolver", "caramel"),
    }
    @receipt = File.join(@system_root, "receipts", "local-integration.json")
    @log = File.join(@root, "launchctl.log")
    result = run(["prepare", @bundle], test: false)
    raise "unable to prepare native fixture: #{result.stderr}" unless result.success?
  end

  def run(args : Array(String),
          *,
          test : Bool = true,
          fixture : String? = nil) : Caramel::Latte::ProcessResult
    env = {"CARAMEL_INSTALLER_FIXTURE" => fixture}
    binary = test ? INTEGRATION_TEST_BINARY : INTEGRATION_BINARY
    Caramel::Checks.run([binary] + args, env: env, timeout: 12.seconds)
  end

  def fixture(jobs : Array(String?), ports : Array(Int32)) : String
    path = File.join(@root, "host.json")
    File.write(path, {
      "root_uid"     => LibC.getuid,
      "destinations" => @destinations,
      "receipt"      => @receipt,
      "system_root"  => @system_root,
      "ports"        => ports,
      "jobs"         => jobs,
      "log"          => @log,
    }.to_json)
    path
  end

  def update_hash(name : String, content : String) : Nil
    File.write(File.join(@bundle, name), content)
    manifest_path = File.join(@bundle, "manifest.json")
    manifest = JSON.parse(File.read(manifest_path))
    manifest["sha256"].as_h[name] = JSON::Any.new(Digest::SHA256.hexdigest(content))
    File.write(manifest_path, manifest.to_json)
  end

  def close : Nil
    FileUtils.rm_rf(@root)
  end
end

private def with_integration_fixture(& : IntegrationFixture ->) : Nil
  fixture = IntegrationFixture.new
  begin
    yield fixture
  ensure
    fixture.close
  end
end

private def integration_job(path : String, relay : String, extra : String = "") : String
  "path = #{path}\nprogram = #{relay}\narguments = {\n#{relay}\n#{extra}}\n"
end

describe "local integration installer" do
  it "prepares exactly the fixed private bundle as the ordinary user" do
    with_integration_fixture do |fixture|
      contents = Dir.children(fixture.bundle).sort
      contents.should eq(["manifest.json", "plist", "relay", "resolver"])
      File.info(fixture.bundle).permissions.value.should eq(0o700)
      contents.each do |name|
        File.info(File.join(fixture.bundle, name)).permissions.value.should eq(0o600)
      end
      manifest = JSON.parse(File.read(File.join(fixture.bundle, "manifest.json")))
      manifest["uid"].as_i.should eq(LibC.getuid.to_i)
      File.read(File.join(fixture.bundle, "resolver")).should contain("port 15353")
    end
  end

  it "reports each installed file as absent, current or stale, as the ordinary user" do
    with_integration_fixture do |fixture|
      host = fixture.fixture([nil] of String?, [] of Int32)
      states = -> do
        status = fixture.run(["status"], fixture: host)
        JSON.parse(status.stdout).as_h.transform_values(&.as_s)
      end
      states.call.should eq({"plist" => "absent", "relay" => "absent", "resolver" => "absent"})
      fixture.destinations.each do |name, path|
        Dir.mkdir_p(File.dirname(path))
        File.copy(File.join(fixture.bundle, name), path)
      end
      states.call.should eq({"plist" => "current", "relay" => "current", "resolver" => "current"})
      File.write(fixture.destinations["plist"], "a plist from another release")
      states.call.should eq({"plist" => "stale", "relay" => "current", "resolver" => "current"})
    end
  end

  it "rejects a modified relay even when its file permissions remain private" do
    with_integration_fixture do |fixture|
      File.write(File.join(fixture.bundle, "relay"), "changed")
      result = fixture.run(["test-validate", fixture.bundle])
      result.success?.should be_false
      result.stderr.should contain("Installation artifact checksum mismatch")
    end
  end

  it "rejects an artifact replaced by a symlink" do
    with_integration_fixture do |fixture|
      path = File.join(fixture.bundle, "relay")
      File.delete(path)
      File.symlink(INTEGRATION_BINARY, path)
      result = fixture.run(["test-validate", fixture.bundle])
      result.success?.should be_false
      result.stderr.should contain("Unexpected file ownership or permissions")
    end
  end

  it "rejects a respecified resolver even with a matching manifest digest" do
    with_integration_fixture do |fixture|
      fixture.update_hash("resolver", "nameserver 8.8.8.8\n")
      result = fixture.run(["test-validate", fixture.bundle])
      result.success?.should be_false
      result.stderr.should contain("Resolver configuration differs from the fixed scope")
    end
  end

  it "rejects a root-owned relay plist even with a matching manifest digest" do
    with_integration_fixture do |fixture|
      plist = File.join(fixture.bundle, "plist")
      replace = ["/usr/bin/plutil", "-replace", "UserName", "-string", "root", "--", plist]
      changed = Caramel::Checks.run(replace)
      changed.success?.should be_true, changed.stderr
      fixture.update_hash("plist", File.read(plist))
      result = fixture.run(["test-validate", fixture.bundle])
      result.success?.should be_false
      result.stderr.should contain("Port relay configuration differs from the fixed template")
    end
  end

  it "rejects a same-label launchd job loaded from another plist" do
    with_integration_fixture do |fixture|
      path = File.join(fixture.root, "job.txt")
      relay = fixture.destinations["relay"]
      File.write(path, integration_job("/Library/LaunchDaemons/foreign.plist", relay))
      no_jobs = fixture.fixture([] of String?, [] of Int32)
      result = fixture.run(["test-verify-job", path], fixture: no_jobs)
      result.success?.should be_false
      result.stderr.should contain("not owned by this installation")
    end
  end

  it "rejects extra arguments on the recorded launchd job" do
    with_integration_fixture do |fixture|
      path = File.join(fixture.root, "job.txt")
      plist, relay = fixture.destinations["plist"], fixture.destinations["relay"]
      File.write(path, integration_job(plist, relay, "--extra\n"))
      no_jobs = fixture.fixture([] of String?, [] of Int32)
      result = fixture.run(["test-verify-job", path], fixture: no_jobs)
      result.success?.should be_false
      result.stderr.should contain("unexpected arguments")
    end
  end

  it "preserves an existing resolver and never writes a receipt" do
    with_integration_fixture do |fixture|
      resolver = fixture.destinations["resolver"]
      Dir.mkdir_p(File.dirname(resolver))
      File.write(resolver, "existing local resolver")
      ports = [Caramel::Checks.free_tcp_port, Caramel::Checks.free_tcp_port]
      host = fixture.fixture([nil] of String?, ports)
      result = fixture.run(["apply", fixture.bundle], fixture: host)
      result.success?.should be_false
      result.stderr.should contain("Existing configuration was preserved")
      File.read(resolver).should eq("existing local resolver")
      File.exists?(fixture.receipt).should be_false
    end
  end

  it "releases the first port reservation when a later port is occupied" do
    with_integration_fixture do |fixture|
      first = Caramel::Checks.free_tcp_port
      occupied = TCPServer.new("127.0.0.1", 0)
      begin
        second = occupied.local_address.port
        while first == second
          first = Caramel::Checks.free_tcp_port
        end
        host = fixture.fixture([nil] of String?, [first, second])
        result = fixture.run(["apply", fixture.bundle], fixture: host)
        result.success?.should be_false
        result.stderr.should contain("Port #{second} is occupied or unavailable")
        File.exists?(fixture.receipt).should be_false
        TCPServer.new("127.0.0.1", first).close
      ensure
        occupied.close
      end
    end
  end

  it "checks ports before rewriting an existing receipt if the job is absent" do
    with_integration_fixture do |fixture|
      first = Caramel::Checks.free_tcp_port
      occupied = TCPServer.new("127.0.0.1", 0)
      begin
        second = occupied.local_address.port
        while first == second
          first = Caramel::Checks.free_tcp_port
        end
        manifest = File.read(File.join(fixture.bundle, "manifest.json"))
        Dir.mkdir_p(File.dirname(fixture.receipt))
        File.write(fixture.receipt, manifest)
        File.chmod(fixture.receipt, 0o600)
        before = File.info(fixture.receipt).modification_time
        host = fixture.fixture([nil] of String?, [first, second])
        result = fixture.run(["apply", fixture.bundle], fixture: host)
        result.success?.should be_false
        result.stderr.should contain("Port #{second} is occupied or unavailable")
        File.read(fixture.receipt).should eq(manifest)
        File.info(fixture.receipt).modification_time.should eq(before)
      ensure
        occupied.close
      end
    end
  end

  it "rolls back fingerprinted files and preserves a competing launchd job" do
    with_integration_fixture do |fixture|
      foreign = "path = /Library/LaunchDaemons/foreign.plist\n"
      port1 = Caramel::Checks.free_tcp_port
      port2 = Caramel::Checks.free_tcp_port
      while port1 == port2
        port2 = Caramel::Checks.free_tcp_port
      end
      host = fixture.fixture([nil, foreign, foreign], [port1, port2])
      result = fixture.run(["apply", fixture.bundle], fixture: host)
      result.success?.should be_false
      result.stderr.should contain("not owned by this installation")
      fixture.destinations.each_value { |path| File.exists?(path).should be_false }
      File.exists?(fixture.receipt).should be_false
      File.exists?(fixture.log).should be_false
    end
  end
end
