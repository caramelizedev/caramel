require "spec"
require "file_utils"
require "../../src/latte/registry"
require "../../src/latte/project_status"
require "../../src/frappe/dev_gateway"

private def error_line(fingerprint : String, error_class : String) : String
  at = "2026-10-03T12:00:00.000Z"
  error = Caramel::Crema::ErrorEvent.new(error_class, fingerprint, false, at)
  error.message = "private message"
  error.location = "app/books.cr:1:1"
  error.to_json
end

describe Caramel::Latte::ProjectStatus do
  it "reads authenticated live development state and preserves a different session's metadata" do
    root = "/private/tmp/caramel-status-#{Random::Secure.hex(6)}"
    Dir.mkdir(root, 0o700)
    paths = Caramel::Latte::Paths.new(root)
    # ameba:disable Lint/UselessAssign -- read by the ensure below
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
      building = {state: "building", owner: "terminal", errors: 0, last_error: nil}
      Caramel::Latte::ProjectStatus.read(paths, site).should eq(building)
      gateway.ready("/private/fixture-app.sock")
      running = {state: "running", owner: "terminal", errors: 0, last_error: nil}
      Caramel::Latte::ProjectStatus.read(paths, site).should eq(running)
      gateway.failed("A compiler error with private details")
      status = Caramel::Latte::ProjectStatus.read(paths, site)
      status.should eq({state: "build-error", owner: "terminal", errors: 0, last_error: nil})
      status.to_json.should_not contain("private details")
      other_session = "/another/session.sock"
      Caramel::Latte::ProjectStatus.remove_session(directory, other_session).should be_false
      Caramel::Latte::ProjectStatus.read(paths, site).should eq(status)
      File.chmod(File.join(directory, "dev-session.json"), 0o644)
      Caramel::Latte::ProjectStatus.read(paths, site)[:state].should eq("unknown")
      File.chmod(File.join(directory, "dev-session.json"), 0o600)
      serving.close
      File.delete?(socket)
      stopped = {state: "stopped", owner: nil, errors: 0, last_error: nil}
      Caramel::Latte::ProjectStatus.read(paths, site).should eq(stopped)
      Caramel::Latte::ProjectStatus.remove_session(directory, socket).should be_true
    ensure
      server.try { |item| item.close unless item.closed? }
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "reports the errors a development session received, and the newest by fingerprint" do
    root = "/private/tmp/caramel-status-errors-#{Random::Secure.hex(6)}"
    Dir.mkdir(root, 0o700)
    paths = Caramel::Latte::Paths.new(root)
    # ameba:disable Lint/UselessAssign -- read by the ensure below
    server : HTTP::Server? = nil
    begin
      registry = Caramel::Latte::Registry.new(paths)
      site = registry.register("bookshelf", root)
      directory = paths.site_run_dir(site.id)
      logs = File.join(root, "logs")
      Dir.mkdir(logs, 0o700)
      events = Caramel::Frappe::DevEvents.new(directory, logs, IO::Memory.new)
      events.start
      gateway = Caramel::Frappe::DevGateway.new(site.origin)
      gateway.events = events
      socket = File.join(directory, "dev-status.sock")
      serving = HTTP::Server.new([gateway])
      server = serving
      serving.bind_unix(socket)
      File.chmod(socket, 0o600)
      spawn { serving.listen }
      site = registry.set_upstream(site.id, socket)
      Caramel::Latte::ProjectStatus.write_session(directory, socket, gateway.owner_token)
      gateway.ready("/private/fixture-app.sock")
      UNIXSocket.open(events.socket) do |client|
        client << error_line("aaaaaaaaaaaa", "KeyError") << "\n"
        client << error_line("bbbbbbbbbbbb", "IndexError") << "\n"
      end
      deadline = Time.instant + 3.seconds
      until events.errors_seen == 2 || Time.instant > deadline
        sleep 10.milliseconds
      end
      status = Caramel::Latte::ProjectStatus.read(paths, site)
      status[:errors].should eq(2)
      newest = status[:last_error].not_nil!
      {newest.fingerprint, newest.error_class}.should eq({"bbbbbbbbbbbb", "IndexError"})
      status.to_json.should_not contain("private message")
    ensure
      events.try(&.close)
      server.try { |item| item.close unless item.closed? }
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end
end
