require "spec"
require "file_utils"
require "../../src/latte/supervisor"
require "../../src/latte/trust"

private def supervisor_ports
  listeners = Array.new(3) { TCPServer.new("127.0.0.1", 0) }
  ports = listeners.map(&.local_address.port)
  {ports[0], ports[1], ports[2]}
ensure
  listeners.try(&.each(&.close))
end

# The version file of the cluster for this release's PostgreSQL major.
private def cluster_version_file(registry : Caramel::Latte::Registry) : String
  data = registry.paths.postgres_data(Caramel::Latte::Postgres::MAJOR)
  File.join(data, "PG_VERSION")
end

describe Caramel::Latte::Supervisor do
  it "starts shared services, reconciles projects and retains databases on stop" do
    root = File.join("/private/tmp", "latte-supervisor-#{Random::Secure.hex(6)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    dns_port, http_port, https_port = supervisor_ports
    supervisor = Caramel::Latte::Supervisor.new(
      registry,
      dns_port: dns_port,
      http_port: http_port,
      https_port: https_port,
    )
    begin
      before = Time.instant
      supervisor.start_services
      (Time.instant - before).should be < 500.milliseconds
      supervisor.await_idle(90.seconds)
      status = JSON.parse(supervisor.status_json)
      %w[postgres dns proxy].each do |name|
        status["services"][name]["state"].as_s.should eq("running")
      end
      site = supervisor.register("bookshelf", root, "caramel")
      # Proxy health checks must not execute project handlers (or depend on
      # how quickly those handlers respond).
      application_requests = 0
      app = HTTP::Server.new do |context|
        application_requests += 1
        context.response.print("application")
      end
      upstream = File.join(registry.paths.site_run_dir(site.id), "health-probe.sock")
      app.bind_unix(upstream)
      File.chmod(upstream, 0o600)
      spawn { app.listen }
      supervisor.set_upstream(site.id, upstream)
      supervisor.monitor
      sleep 3.3.seconds
      supervisor.stop_monitor
      application_requests.should eq(0)
      JSON.parse(supervisor.status_json)["services"]["proxy"]["state"].as_s.should eq("running")
      app.close
      File.exists?(supervisor.proxy.root_certificate).should be_true
      trust = Caramel::Latte::Trust.new(registry.paths, supervisor.proxy)
      trust.fingerprint.should match(/\A[0-9a-f]{64}\z/)
      trust_directory = File.join(root, "trust")
      Dir.mkdir(trust_directory, 0o700)
      # A receipt recorded for another authority.
      other_authority = {version: 1, sha256: "0" * 64}.to_json
      receipt = File.join(trust_directory, "receipt.json")
      Caramel::Latte::ConfigFile.write(receipt, other_authority)
      expect_raises(Caramel::Latte::PublicError, /rotating/) { trust.install }
      supervisor.unregister(site.id).should be_true
      supervisor.postgres.credentials(site).development_runtime.should contain("postgres")
      supervisor.stop_services
      supervisor.await_idle(60.seconds)
      status = JSON.parse(supervisor.status_json)
      %w[postgres dns proxy].each do |name|
        status["services"][name]["state"].as_s.should eq("stopped")
      end
      File.exists?(cluster_version_file(registry)).should be_true
    ensure
      supervisor.stop_monitor
      app.try { |server| server.close unless server.closed? }
      supervisor.stop_services
      supervisor.await_idle(60.seconds)
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "preserves an occupied listener and cleans up services from a failed startup" do
    root = File.join("/private/tmp", "latte-start-failure-#{Random::Secure.hex(6)}")
    registry = Caramel::Latte::Registry.new(root)
    dns_port, _, https_port = supervisor_ports
    occupied = TCPServer.new("127.0.0.1", 0)
    supervisor = Caramel::Latte::Supervisor.new(
      registry,
      dns_port: dns_port,
      http_port: occupied.local_address.port,
      https_port: https_port,
    )
    begin
      supervisor.start_services
      supervisor.await_idle(30.seconds)
      status = JSON.parse(supervisor.status_json)
      status["services"]["proxy"]["state"].as_s.should eq("failed")
      supervisor.postgres.running?.should be_false
      occupied.closed?.should be_false
      File.exists?(cluster_version_file(registry)).should be_true
    ensure
      supervisor.stop_services
      supervisor.await_idle(60.seconds)
      occupied.close
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "shows a refused earlier-toolchain service in its status instead of 'check Latte logs'" do
    root = File.join("/private/tmp", "latte-refused-#{Random::Secure.hex(6)}")
    registry = Caramel::Latte::Registry.new(root)
    dns_port, http_port, https_port = supervisor_ports
    supervisor = Caramel::Latte::Supervisor.new(
      registry,
      dns_port: dns_port,
      http_port: http_port,
      https_port: https_port,
    )
    # A live process the DNS record names, at a path outside any toolchain's installs.
    stranger = File.join(root, "stranger", "sl-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(File.dirname(stranger), mode: 0o700)
    File.copy("/bin/sleep", stranger)
    File.chmod(stranger, 0o700)
    Process.run("/usr/bin/codesign", ["--force", "--sign", "-", stranger],
      output: Process::Redirect::Close, error: Process::Redirect::Close).success?.should be_true
    stranger = File.realpath(stranger)
    Dir.mkdir_p(registry.paths.dns_dir, mode: 0o700)
    record = File.join(registry.paths.dns_dir, "process.json")
    log = File.join(root, "stranger.log")
    started = Caramel::Latte::ManagedChild.new("dns", stranger, ["5"], record, log).start
    begin
      supervisor.start_services
      supervisor.await_idle(90.seconds)
      status = JSON.parse(supervisor.status_json)
      status["services"]["dns"]["state"].as_s.should eq("failed")
      message = status["error"].as_s
      message.should contain("dns PID #{started.pid} runs #{stranger}")
      message.should contain("but this Latte runs")
      message.should_not contain("check Latte logs")
      Process.exists?(started.pid).should be_true
    ensure
      Process.signal(Signal::KILL, started.pid) rescue nil
      supervisor.stop_services
      supervisor.await_idle(60.seconds)
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end
end
