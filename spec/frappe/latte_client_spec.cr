require "spec"
require "file_utils"
require "http/server"
require "../../src/frappe/latte_client"

describe Caramel::Frappe::LatteClient do
  it "uses private HTTP IPC and rejects incompatible, malformed and oversized responses" do
    root = "/private/tmp/caramel-client-live-#{Random::Secure.hex(8)}"
    paths = Caramel::Latte::Paths.new(root)
    server = HTTP::Server.new do |context|
      context.response.headers["Content-Type"] = "application/json"
      context.response.headers["Connection"] = "close"
      case context.request.path
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
end
