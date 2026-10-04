require "spec"
require "file_utils"
require "../../src/latte/server"
require "../../src/latte/postgres"

private class TestServices < Caramel::Latte::ServiceControl
  getter starts = 0
  getter stops = 0

  def initialize(@registry : Caramel::Latte::Registry)
  end

  def status_json(version : Int32) : String
    stopped = {state: "stopped"}
    {version: version, services: {postgres: stopped, dns: stopped, proxy: stopped}}.to_json
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
    unless site
      raise Caramel::Latte::PublicError.new("not_found", "Project is not registered", 404)
    end
    unless site.directory == File.realpath(directory)
      raise ArgumentError.new("Project directory differs from registration")
    end
    environment = {
      DATABASE_URL:      "private-test-connection",
      SPEC_DATABASE_URL: "private-test-spec",
    }
    {version: 1, environment: environment}.to_json
  end

  getter branches = [] of String

  def create_branch_json(id : String, name : String) : String
    database = Caramel::Latte::Postgres.branch_database(id, name)
    if @branches.includes?(name)
      message = "Branch #{name} already exists; delete it first"
      raise Caramel::Latte::PublicError.new("branch_exists", message, 409)
    end
    @branches << name
    branch = {
      name:          name,
      database:      database,
      migration_url: "private-migration",
      runtime_url:   "private-runtime",
    }
    {version: 1, branch: branch}.to_json
  end

  def branches_json(id : String) : String
    branches = @branches.map do |name|
      {name: name, database: Caramel::Latte::Postgres.branch_database(id, name)}
    end
    {version: 1, branches: branches}.to_json
  end

  def drop_branch(id : String, name : String) : Bool
    Caramel::Latte::Postgres.branch_database(id, name)
    !@branches.delete(name).nil?
  end

  getter workers = [] of Int32

  def test_worker_json(id : String, index : Int32) : String
    database = Caramel::Latte::Postgres.test_worker_database(id, index)
    @workers << index unless @workers.includes?(index)
    worker = {
      index:         index,
      database:      database,
      migration_url: "private-migration-w#{index}",
      runtime_url:   "private-runtime-w#{index}",
    }
    {version: 1, worker: worker}.to_json
  end

  def drop_test_worker(id : String, index : Int32) : Bool
    Caramel::Latte::Postgres.test_worker_database(id, index)
    !@workers.delete(index).nil?
  end
end

# A control API request. A body is sent as JSON unless *headers* are given.
private def control_request(method : String,
                            path : String,
                            body : String? = nil,
                            headers : HTTP::Headers? = nil) : HTTP::Request
  json = HTTP::Headers{"Content-Type" => "application/json"}
  headers ||= body ? json : HTTP::Headers.new
  HTTP::Request.new(method, path, headers, body)
end

# The server's answer to a control API request.
private def answer(server : Caramel::Latte::Server,
                   method : String,
                   path : String,
                   body : String? = nil,
                   headers : HTTP::Headers? = nil) : Caramel::Response
  server.handle(control_request(method, path, body, headers))
end

describe Caramel::Latte::Server do
  it "refuses service mutations after the request budget expires" do
    root = File.join("/private/tmp", "latte-api-deadline-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    begin
      services = TestServices.new(registry)
      server = Caramel::Latte::Server.new(registry, services)
      request = control_request("POST", "/v1/services/start", "{}")
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

  # scripts/check latte-ipc proves the trickle cut-off with scaled-down
  # limits, so this keeps the daemon's own.
  it "gives the daemon's control connections a 5 s idle timeout and a 12 s request deadline" do
    root = File.join("/private/tmp", "latte-api-limits-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    begin
      server = Caramel::Latte::Server.new(registry, TestServices.new(registry))
      server.idle_timeout.should eq(5.seconds)
      server.request_deadline.should eq(12.seconds)
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
      registration = {name: "bookshelf", directory: root}.to_json
      response = answer(server, "POST", "/v1/sites", registration)
      response.status.should eq(201)
      site = JSON.parse(response.body)["site"]
      site["origin"].as_s.should eq("https://bookshelf.caramel")
      site["domain"].as_s.should eq("bookshelf.caramel")
      site_path = "/v1/sites/#{site["id"].as_s}"
      nonmatching = {socket: "/private/nonmatching.sock"}.to_json
      clear = answer(server, "DELETE", "#{site_path}/upstream", nonmatching)
      clear.status.should eq(200)
      JSON.parse(clear.body)["cleared"].as_bool.should be_false
      endpoint = "#{site_path}/environment"
      secrets = answer(server, "POST", endpoint, {directory: root}.to_json)
      secrets.status.should eq(200)
      environment = JSON.parse(secrets.body)["environment"]
      environment["DATABASE_URL"].as_s.should eq("private-test-connection")
      secrets.headers["Cache-Control"].should eq("no-store")
      answer(server, "GET", endpoint).status.should eq(404)
      answer(server, "POST", endpoint, %({"directory":"/private/tmp"})).status.should eq(400)
      sites = answer(server, "GET", "/v1/sites").body
      sites.should_not contain("private-test-connection")
      JSON.parse(sites)["sites"].as_a.size.should eq(1)
      answer(server, "POST", "/v1/services/start", "{}").status.should eq(200)
      services.starts.should eq(1)
      answer(server, "POST", "/v1/services/stop", "{}").status.should eq(200)
      services.stops.should eq(1)
      other = answer(server, "GET", "/v3/status")
      other.status.should eq(404)
      refusal = JSON.parse(other.body)
      reported = {
        refusal["error"]["code"].as_s,
        refusal["latte"].as_s,
        refusal["api"].as_a.map(&.as_i),
      }
      reported.should eq({"unsupported_api", Caramel::VERSION, [1, 2]})
      oversized = "{" + " " * 16384
      answer(server, "POST", "/v1/services/start", oversized).status.should eq(413)
      services.starts.should eq(1)
      answer(server, "POST", "/v1/services/start", %({"extra":true})).status.should eq(400)
      privileged = %({"name":"bad","directory":"/missing","admin":true})
      answer(server, "POST", "/v1/sites", privileged).status.should eq(400)
      answer(server, "POST", "/v1/sites", "{}", HTTP::Headers.new).status.should eq(415)
      answer(server, "DELETE", site_path).status.should eq(200)
      Dir.exists?(root).should be_true
      registry.list.should be_empty
      answer(server, "GET", "/unknown").status.should eq(404)
    ensure
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "adds error fields to a site in version 2 only, and stamps bodies with the version asked" do
    root = File.join("/private/tmp", "latte-api-v2-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    begin
      server = Caramel::Latte::Server.new(registry, TestServices.new(registry))
      registration = {name: "bookshelf", directory: root}.to_json
      answer(server, "POST", "/v2/sites", registration).status.should eq(201)
      v2 = JSON.parse(answer(server, "GET", "/v2/sites").body)
      v2["version"].as_i.should eq(2)
      listed = v2["sites"][0]
      listed["errors"].as_i.should eq(0)
      listed["last_error"].raw.should be_nil
      v1 = JSON.parse(answer(server, "GET", "/v1/sites").body)
      v1["version"].as_i.should eq(1)
      v1["sites"][0].as_h.has_key?("errors").should be_false
      v1["sites"][0].as_h.has_key?("last_error").should be_false
      missing = JSON.parse(answer(server, "DELETE", "/v2/sites/0123456789abcdef").body)
      {missing["version"].as_i, missing["error"]["code"].as_s}.should eq({2, "not_found"})
      answer(server, "GET", "/status").status.should eq(404)
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
      endpoint = "/v1/sites/0123456789abcdef/branches"
      diff = {name: "diff_1a2b"}.to_json
      created = answer(server, "POST", endpoint, diff)
      created.status.should eq(201)
      JSON.parse(created.body)["branch"]["runtime_url"].as_s.should eq("private-runtime")
      created.headers["Cache-Control"].should eq("no-store")
      answer(server, "POST", endpoint, diff).status.should eq(409)
      invalid = {name: "Feat-Stripe"}.to_json
      answer(server, "POST", endpoint, invalid).status.should eq(400)
      templated = {name: "x", template: "postgres"}.to_json
      answer(server, "POST", endpoint, templated).status.should eq(400)
      listed = JSON.parse(answer(server, "GET", endpoint).body)["branches"].as_a
      listed.map(&.["name"].as_s).should eq(["diff_1a2b"])
      listed.to_json.should_not contain("private-")
      answer(server, "DELETE", "#{endpoint}/diff_1a2b").status.should eq(200)
      answer(server, "DELETE", "#{endpoint}/diff_1a2b").status.should eq(404)
      answer(server, "DELETE", "#{endpoint}/DROP%20DATABASE").status.should eq(400)
      answer(server, "GET", "#{endpoint}/diff_1a2b").status.should eq(404)
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
      endpoint = "/v1/sites/0123456789abcdef/test-workers"
      created = answer(server, "POST", "#{endpoint}/2", "{}")
      created.status.should eq(200)
      worker = JSON.parse(created.body)["worker"]
      worker["database"].as_s.should eq("caramel_spec_0123456789abcdef_w2")
      worker["runtime_url"].as_s.should eq("private-runtime-w2")
      worker["migration_url"].as_s.should eq("private-migration-w2")
      created.headers["Cache-Control"].should eq("no-store")
      # Posting again resets the same worker.
      answer(server, "POST", "#{endpoint}/2", "{}").status.should eq(200)
      services.workers.should eq([2])
      templated = %({"template":"caramel_dev_0123456789abcdef"})
      answer(server, "POST", "#{endpoint}/2", templated).status.should eq(400)
      answer(server, "POST", "#{endpoint}/2", "{}", HTTP::Headers.new).status.should eq(415)
      %w[0 9 two 100].each do |index|
        answer(server, "POST", "#{endpoint}/#{index}", "{}").status.should eq(400)
      end
      answer(server, "GET", "#{endpoint}/2").status.should eq(404)
      answer(server, "DELETE", "#{endpoint}/2").status.should eq(200)
      answer(server, "DELETE", "#{endpoint}/2").status.should eq(404)
      answer(server, "DELETE", "#{endpoint}/9").status.should eq(400)
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
      headers = HTTP::Headers{
        "Content-Type" => "application/json",
        "Connection"   => "close",
      }
      response = HTTP::Client.new(socket).post("/v1/daemon/stop", headers, "{}")
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
