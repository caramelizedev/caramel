require "spec"
require "file_utils"
require "../../src/latte/registry"
require "../../src/latte/project_status"
require "../../src/frappe/dev_gateway"

describe Caramel::Latte::ProjectStatus do
  it "reads authenticated live development state and preserves a different session's metadata" do
    root = "/private/tmp/caramel-status-#{Random::Secure.hex(6)}"
    Dir.mkdir(root, 0o700)
    paths = Caramel::Latte::Paths.new(root)
    # ameba:disable Lint/UselessAssign
    server : HTTP::Server? = nil
    begin
      registry = Caramel::Latte::Registry.new(paths)
      site = registry.register("bookshelf", root)
      directory = paths.site_run_dir(site.id)
      socket = File.join(directory, "dev-status.sock")
      gateway = Caramel::Frappe::DevGateway.new(site.origin)
      serving = HTTP::Server.new([gateway])
      server = serving
      serving.bind_unix(socket)
      File.chmod(socket, 0o600)
      spawn { serving.listen }
      site = registry.set_upstream(site.id, socket)
      Caramel::Latte::ProjectStatus.write_session(directory, socket, gateway.owner_token)
      Caramel::Latte::ProjectStatus.read(paths, site).should eq({state: "building", owner: "terminal"})
      gateway.ready("/private/fixture-app.sock")
      Caramel::Latte::ProjectStatus.read(paths, site).should eq({state: "running", owner: "terminal"})
      gateway.failed("A compiler error with private details")
      status = Caramel::Latte::ProjectStatus.read(paths, site)
      status.should eq({state: "build-error", owner: "terminal"})
      status.to_json.should_not contain("private details")
      Caramel::Latte::ProjectStatus.remove_session(directory, "/another/session.sock").should be_false
      Caramel::Latte::ProjectStatus.read(paths, site).should eq(status)
      File.chmod(File.join(directory, "dev-session.json"), 0o644)
      Caramel::Latte::ProjectStatus.read(paths, site)[:state].should eq("unknown")
      File.chmod(File.join(directory, "dev-session.json"), 0o600)
      serving.close
      File.delete?(socket)
      Caramel::Latte::ProjectStatus.read(paths, site).should eq({state: "stopped", owner: nil})
      Caramel::Latte::ProjectStatus.remove_session(directory, socket).should be_true
    ensure
      server.try { |item| item.close unless item.closed? }
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end
end
