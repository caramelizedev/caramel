require "spec"
require "file_utils"
require "http/server"
require "../../src/frappe/latte_client"

describe Caramel::Frappe::LatteClient do
  it "uses private HTTP IPC and rejects incompatible, malformed and oversized responses" do
    root = "/private/tmp/caramel-client-live-#{Random::Secure.hex(8)}"
    paths = Caramel::Latte::Paths.new(root)
    removed = Channel(String).new(1)
    server = HTTP::Server.new do |context|
      context.response.headers["Content-Type"] = "application/json"
      context.response.headers["Connection"] = "close"
      case context.request.path
      when "/v1/sites/0123456789abcdef"
        removed.send("#{context.request.method} #{context.request.path}")
        context.response.print(%({"version":1}))
      when "/v1/status"
        context.response.print(%({"version":1,"services":{"postgres":{"state":"running"},"dns":{"state":"running"},"proxy":{"state":"running"}}}))
      when "/old"
        context.response.print(%({"version":2}))
      when "/large"
        context.response.print(" " * (Caramel::Frappe::LatteClient::MAX_RESPONSE + 1))
      when "/invalid"
        context.response.print("not json")
      else
        context.response.status_code = 409
        context.response.print(%({"version":1,"error":{"message":"Project is already registered"}}))
      end
    end
    begin
      server.bind_unix(paths.control_socket)
      File.chmod(paths.control_socket, 0o600)
      spawn { server.listen }
      client = Caramel::Frappe::LatteClient.new(root)
      client.ready!(1.second)
      client.status["services"]["postgres"]["state"].as_s.should eq("running")
      expect_raises(Caramel::Frappe::Error, "API version") { client.request("GET", "/old") }
      expect_raises(Caramel::Frappe::Error, "1 MiB") { client.request("GET", "/large") }
      expect_raises(Caramel::Frappe::Error, "invalid response") { client.request("GET", "/invalid") }
      expect_raises(Caramel::Frappe::Error, "already registered") { client.request("POST", "/conflict", "{}") }
      client.unregister("0123456789abcdef")
      removed.receive.should eq("DELETE /v1/sites/0123456789abcdef")
    ensure
      server.close
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "reports an unavailable daemon without creating state" do
    root = "/private/tmp/caramel-no-daemon-#{Random::Secure.hex(8)}"
    client = Caramel::Frappe::LatteClient.new(root)
    expect_raises(Caramel::Frappe::Error, "Latte is unavailable") { client.status }
    File.exists?(root).should be_false
  end

  it "starts Latte with its launcher when none is running, then waits for it" do
    root = "/private/tmp/caramel-client-start-#{Random::Secure.hex(8)}"
    paths = Caramel::Latte::Paths.new(root)
    launched = File.join(root, "launched")
    launcher = File.join(root, "latte")
    File.write(launcher, "#!/bin/sh\necho \"$@\" > '#{launched}'\n", perm: 0o700)
    server = HTTP::Server.new do |context|
      context.response.headers["Content-Type"] = "application/json"
      context.response.print(%({"version":1,"services":{"postgres":{"state":"running"},"dns":{"state":"running"},"proxy":{"state":"running"}}}))
    end
    # Plays the daemon the launcher started.
    spawn do
      until File.exists?(launched)
        sleep 10.milliseconds
      end
      server.bind_unix(paths.control_socket)
      File.chmod(paths.control_socket, 0o600)
      server.listen
    end
    begin
      Caramel::Frappe::LatteClient.new(root, launcher).ready!(5.seconds)
      File.read(launched).should eq("daemon --detach\n")
    ensure
      server.close
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "reports why the Latte it started did not come up" do
    root = "/private/tmp/caramel-client-failed-start-#{Random::Secure.hex(8)}"
    paths = Caramel::Latte::Paths.new(root)
    log = File.join(paths.logs_dir, "latte.log")
    launcher = File.join(root, "latte")
    File.write(launcher, "#!/bin/sh\necho 'No Caramel toolchain is installed. Run scripts/install-toolchain.' >> '#{log}'\nexit 1\n", perm: 0o700)
    begin
      expect_raises(Caramel::Frappe::Error, "Latte did not start: No Caramel toolchain is installed. Run scripts/install-toolchain. Log: #{log}") do
        Caramel::Frappe::LatteClient.new(root, launcher).ready!(5.seconds)
      end
    ensure
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "refuses a regular file where the private daemon socket belongs" do
    root = "/private/tmp/caramel-client-#{Random::Secure.hex(8)}"
    paths = Caramel::Latte::Paths.new(root)
    begin
      File.write(paths.control_socket, "not a socket", perm: 0o600)
      client = Caramel::Frappe::LatteClient.new(root)
      expect_raises(Caramel::Frappe::Error, "socket") { client.status }
      File.read(paths.control_socket).should eq("not a socket")
    ensure
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "locks one site against a second development session and does not create absent logs" do
    root = "/private/tmp/caramel-client-lock-#{Random::Secure.hex(8)}"
    paths = Caramel::Latte::Paths.new(root)
    client = Caramel::Frappe::LatteClient.new(root)
    id = "0123456789abcdef"
    begin
      client.site_log_directory(id, create: false).should be_nil
      client.with_site_lock(id, "bookshelf") do
        expect_raises(Caramel::Frappe::Error, "A development session is already running for bookshelf") do
          client.with_site_lock(id, "bookshelf") { }
        end
      end
    ensure
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "derives a branch URL exactly as Latte builds one for the same role" do
    socket = "/private/tmp/latte state/run"
    password = "0f" * 32
    development = Caramel::Latte::Postgres.connection_url("caramel_dev_0123456789abcdef", password, "caramel_dev_0123456789abcdef", socket)
    branch = Caramel::Latte::Postgres.branch_database("0123456789abcdef", "feature_x")
    expected = Caramel::Latte::Postgres.connection_url("caramel_dev_0123456789abcdef", password, branch, socket)
    Caramel::Frappe::LatteClient.branch_url(development, branch).should eq(expected)
  end
end
