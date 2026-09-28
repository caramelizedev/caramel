require "spec"
require "file_utils"
require "../../src/latte/server"
require "../../src/latte/postgres"

private class TestServices < Caramel::Latte::ServiceControl
  getter starts = 0
  getter stops = 0

  def initialize(@registry : Caramel::Latte::Registry)
  end

  def status_json : String
    %({"version":1,"services":{"postgres":{"state":"stopped"},"dns":{"state":"stopped"},"proxy":{"state":"stopped"}}})
  end

  def start_services : Nil
    @starts += 1
  end

  def stop_services : Nil
    @stops += 1
  end

  def register(name : String, directory : String, suffix : String) : Caramel::Latte::Site
    @registry.register(name, directory, suffix)
  end

  def unregister(id : String) : Bool
    !@registry.unregister(id).nil?
  end

  def set_upstream(id : String, socket : String) : Caramel::Latte::Site
    @registry.set_upstream(id, socket)
  end

  def clear_upstream(id : String, socket : String) : Bool
    !@registry.clear_upstream(id, socket).nil?
  end

  def environment_json(id : String, directory : String) : String
    site = @registry.find(id)
    raise Caramel::Latte::PublicError.new("not_found", "Project is not registered", 404) unless site
    raise ArgumentError.new("Project directory differs from registration") unless site.directory == File.realpath(directory)
    {version: 1, environment: {DATABASE_URL: "private-test-connection", SPEC_DATABASE_URL: "private-test-spec"}}.to_json
  end

  getter branches = [] of String

  def create_branch_json(id : String, name : String) : String
    database = Caramel::Latte::Postgres.branch_database(id, name)
    raise Caramel::Latte::PublicError.new("branch_exists", "Branch #{name} already exists; delete it first", 409) if @branches.includes?(name)
    @branches << name
    {version: 1, branch: {name: name, database: database, migration_url: "private-migration", runtime_url: "private-runtime"}}.to_json
  end

  def branches_json(id : String) : String
    {version: 1, branches: @branches.map { |name| {name: name, database: Caramel::Latte::Postgres.branch_database(id, name)} }}.to_json
  end

  def drop_branch(id : String, name : String) : Bool
    Caramel::Latte::Postgres.branch_database(id, name)
    !@branches.delete(name).nil?
  end

  getter workers = [] of Int32

  def test_worker_json(id : String, index : Int32) : String
    database = Caramel::Latte::Postgres.test_worker_database(id, index)
    @workers << index unless @workers.includes?(index)
    {version: 1, worker: {index: index, database: database, migration_url: "private-migration-w#{index}", runtime_url: "private-runtime-w#{index}"}}.to_json
  end

  def drop_test_worker(id : String, index : Int32) : Bool
    Caramel::Latte::Postgres.test_worker_database(id, index)
    !@workers.delete(index).nil?
  end
end

describe Caramel::Latte::Server do
  it "refuses service mutations after the request budget expires" do
    root = File.join("/private/tmp", "latte-api-deadline-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    begin
      services = TestServices.new(registry)
      server = Caramel::Latte::Server.new(registry, services)
      request = HTTP::Request.new("POST", "/v1/services/start", HTTP::Headers{"Content-Type" => "application/json"}, "{}")
      Caramel::Latte::OperationDeadline.run(1.millisecond) do
        sleep 5.milliseconds
        server.handle(request).status.should eq(503)
      end
      services.starts.should eq(0)
    ensure
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "shares a versioned site/service API and bounds mutations" do
    root = File.join("/private/tmp", "latte-api-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    begin
      services = TestServices.new(registry)
      server = Caramel::Latte::Server.new(registry, services)
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      response = server.handle(HTTP::Request.new("POST", "/v1/sites", headers, {name: "bookshelf", directory: root}.to_json))
      response.status.should eq(201)
      site = JSON.parse(response.body)["site"]
      site["origin"].as_s.should eq("https://bookshelf.caramel")
      site["domain"].as_s.should eq("bookshelf.caramel")
      clear = server.handle(HTTP::Request.new("DELETE", "/v1/sites/#{site["id"].as_s}/upstream", headers, {socket: "/private/nonmatching.sock"}.to_json))
      clear.status.should eq(200)
      JSON.parse(clear.body)["cleared"].as_bool.should be_false
      endpoint = "/v1/sites/#{site["id"].as_s}/environment"
      secrets = server.handle(HTTP::Request.new("POST", endpoint, headers, {directory: root}.to_json))
      secrets.status.should eq(200)
      JSON.parse(secrets.body)["environment"]["DATABASE_URL"].as_s.should eq("private-test-connection")
      secrets.headers["Cache-Control"].should eq("no-store")
      server.handle(HTTP::Request.new("GET", endpoint)).status.should eq(404)
      server.handle(HTTP::Request.new("POST", endpoint, headers, %({"directory":"/private/tmp"}))).status.should eq(400)
      server.handle(HTTP::Request.new("GET", "/v1/sites")).body.should_not contain("private-test-connection")
      JSON.parse(server.handle(HTTP::Request.new("GET", "/v1/sites")).body)["sites"].as_a.size.should eq(1)
      server.handle(HTTP::Request.new("POST", "/v1/services/start", headers, "{}")).status.should eq(200)
      services.starts.should eq(1)
      server.handle(HTTP::Request.new("POST", "/v1/services/stop", headers, "{}")).status.should eq(200)
      services.stops.should eq(1)
      server.handle(HTTP::Request.new("POST", "/v1/services/start", headers, "{" + " " * 16384)).status.should eq(413)
      services.starts.should eq(1)
      server.handle(HTTP::Request.new("POST", "/v1/services/start", headers, %({"extra":true}))).status.should eq(400)
      server.handle(HTTP::Request.new("POST", "/v1/sites", headers, %({"name":"bad","directory":"/missing","admin":true}))).status.should eq(400)
      server.handle(HTTP::Request.new("POST", "/v1/sites", HTTP::Headers.new, "{}")).status.should eq(415)
      server.handle(HTTP::Request.new("DELETE", "/v1/sites/#{site["id"].as_s}")).status.should eq(200)
      Dir.exists?(root).should be_true
      registry.list.should be_empty
      server.handle(HTTP::Request.new("GET", "/unknown")).status.should eq(404)
    ensure
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "creates, lists and deletes database branches through the versioned API" do
    root = File.join("/private/tmp", "latte-api-branches-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    begin
      services = TestServices.new(registry)
      server = Caramel::Latte::Server.new(registry, services)
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      endpoint = "/v1/sites/0123456789abcdef/branches"
      created = server.handle(HTTP::Request.new("POST", endpoint, headers, {name: "diff_1a2b"}.to_json))
      created.status.should eq(201)
      JSON.parse(created.body)["branch"]["runtime_url"].as_s.should eq("private-runtime")
      created.headers["Cache-Control"].should eq("no-store")
      server.handle(HTTP::Request.new("POST", endpoint, headers, {name: "diff_1a2b"}.to_json)).status.should eq(409)
      server.handle(HTTP::Request.new("POST", endpoint, headers, {name: "Feat-Stripe"}.to_json)).status.should eq(400)
      server.handle(HTTP::Request.new("POST", endpoint, headers, {name: "x", template: "postgres"}.to_json)).status.should eq(400)
      listed = JSON.parse(server.handle(HTTP::Request.new("GET", endpoint)).body)["branches"].as_a
      listed.map(&.["name"].as_s).should eq(["diff_1a2b"])
      listed.to_json.should_not contain("private-")
      server.handle(HTTP::Request.new("DELETE", "#{endpoint}/diff_1a2b")).status.should eq(200)
      server.handle(HTTP::Request.new("DELETE", "#{endpoint}/diff_1a2b")).status.should eq(404)
      server.handle(HTTP::Request.new("DELETE", "#{endpoint}/DROP%20DATABASE")).status.should eq(400)
      server.handle(HTTP::Request.new("GET", "#{endpoint}/diff_1a2b")).status.should eq(404)
      services.branches.should be_empty
    ensure
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "creates, resets and drops Corretto test worker databases through the versioned API" do
    root = File.join("/private/tmp", "latte-api-workers-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    begin
      services = TestServices.new(registry)
      server = Caramel::Latte::Server.new(registry, services)
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      endpoint = "/v1/sites/0123456789abcdef/test-workers"
      created = server.handle(HTTP::Request.new("POST", "#{endpoint}/2", headers, "{}"))
      created.status.should eq(200)
      worker = JSON.parse(created.body)["worker"]
      worker["database"].as_s.should eq("caramel_spec_0123456789abcdef_w2")
      worker["runtime_url"].as_s.should eq("private-runtime-w2")
      worker["migration_url"].as_s.should eq("private-migration-w2")
      created.headers["Cache-Control"].should eq("no-store")
      # Posting again resets the same worker.
      server.handle(HTTP::Request.new("POST", "#{endpoint}/2", headers, "{}")).status.should eq(200)
      services.workers.should eq([2])
      server.handle(HTTP::Request.new("POST", "#{endpoint}/2", headers, %({"template":"caramel_dev_0123456789abcdef"}))).status.should eq(400)
      server.handle(HTTP::Request.new("POST", "#{endpoint}/2", HTTP::Headers.new, "{}")).status.should eq(415)
      %w(0 9 two 100).each do |index|
        server.handle(HTTP::Request.new("POST", "#{endpoint}/#{index}", headers, "{}")).status.should eq(400)
      end
      server.handle(HTTP::Request.new("GET", "#{endpoint}/2")).status.should eq(404)
      server.handle(HTTP::Request.new("DELETE", "#{endpoint}/2")).status.should eq(200)
      server.handle(HTTP::Request.new("DELETE", "#{endpoint}/2")).status.should eq(404)
      server.handle(HTTP::Request.new("DELETE", "#{endpoint}/9")).status.should eq(400)
      services.workers.should be_empty
    ensure
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "answers a stop request, then stops listening" do
    root = File.join("/private/tmp", "latte-api-stop-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    server = Caramel::Latte::Server.new(registry, TestServices.new(registry))
    stopped = Channel(Nil).new(1)
    spawn do
      server.listen
      stopped.send(nil)
    end
    begin
      socket_path = registry.paths.control_socket
      until File.exists?(socket_path)
        sleep 10.milliseconds
      end
      socket = UNIXSocket.new(socket_path)
      response = HTTP::Client.new(socket).post("/v1/daemon/stop", HTTP::Headers{"Content-Type" => "application/json", "Connection" => "close"}, "{}")
      response.status_code.should eq(200)
      JSON.parse(response.body)["stopping"].as_bool.should be_true
      select
      when stopped.receive
      when timeout(5.seconds)
        fail "the server kept listening after a stop request"
      end
    ensure
      server.close
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end
end
