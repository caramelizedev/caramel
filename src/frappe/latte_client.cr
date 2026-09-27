require "http/client"
require "socket/unix_socket"
require "./project"
require "../latte/postgres"

module Caramel::Frappe
  # Frappé and the menu application speak to the same private service owner.
  # Constructing or inspecting this client never creates Latte state.
  class LatteClient
    MAX_RESPONSE = 1024 * 1024
    getter socket_path : String
    getter root : String

    def initialize(root : String? = nil)
      selected = root || ENV["CARAMEL_HOME"]? || Latte::Paths::DEFAULT_ROOT
      @root = Latte::StateSecurity.canonical_creation_path(selected)
      @runtime = Latte::StateSecurity.runtime_root(@root)
      @socket_path = File.join(@runtime, "latte.sock")
    end

    def status : JSON::Any
      request("GET", "/v1/status")
    end

    def sites : Array(JSON::Any)
      request("GET", "/v1/sites")["sites"].as_a
    end

    def start_services : JSON::Any
      request("POST", "/v1/services/start", "{}")
    end

    def stop_services : JSON::Any
      request("POST", "/v1/services/stop", "{}")
    end

    def ready!(timeout : Time::Span = 95.seconds) : Nil
      deadline = Time.instant + timeout
      current = status
      states = service_states(current)
      start_services unless states.all? { |state| state == "running" } || states.any? { |state| state == "starting" }
      loop do
        current = status
        states = service_states(current)
        return if states.all? { |state| state == "running" }
        if current["error"]?.try(&.as_s?) || states.any? { |state| state == "failed" }
          raise Error.new(current["error"]?.try(&.as_s?) || "Latte services failed; inspect frappe services")
        end
        raise Error.new("Latte services did not become ready; inspect frappe services") if Time.instant >= deadline
        sleep 200.milliseconds
      end
    end

    def register(project : Project) : JSON::Any
      request("POST", "/v1/sites", {name: project.name, directory: project.root, suffix: project.metadata.domain_suffix}.to_json)["site"]
    end

    def unregister(id : String) : Nil
      validate_id(id)
      request("DELETE", "/v1/sites/#{id}")
      nil
    end

    def environment(id : String, directory : String) : Hash(String, String)
      validate_id(id)
      request("POST", "/v1/sites/#{id}/environment", {directory: directory}.to_json)["environment"].as_h.transform_values(&.as_s)
    end

    def set_upstream(id : String, socket : String) : JSON::Any
      validate_id(id)
      request("POST", "/v1/sites/#{id}/upstream", {socket: socket}.to_json)["site"]
    end

    def clear_upstream(id : String, socket : String) : Bool
      validate_id(id)
      request("DELETE", "/v1/sites/#{id}/upstream", {socket: socket}.to_json)["cleared"].as_bool
    end

    # A disposable copy of the site's development database. The returned
    # document holds `name`, `database`, `migration_url` and `runtime_url`.
    def create_branch(id : String, name : String) : JSON::Any
      validate_id(id)
      request("POST", "/v1/sites/#{id}/branches", {name: name}.to_json)["branch"]
    end

    def branches(id : String) : Array(JSON::Any)
      validate_id(id)
      request("GET", "/v1/sites/#{id}/branches")["branches"].as_a
    end

    def drop_branch(id : String, name : String) : Nil
      validate_id(id)
      raise Error.new("Invalid branch name") unless name.matches?(Latte::Postgres::BRANCH_NAME)
      request("DELETE", "/v1/sites/#{id}/branches/#{name}")
      nil
    end

    # A branch admits the same development runtime role as the database it
    # was cloned from, so its URL is the development URL with the branch's
    # database name; listings deliberately carry no credentials.
    def self.branch_url(database_url : String, database : String) : String
      uri = URI.parse(database_url)
      uri.path = "/#{database}"
      uri.to_s
    end

    # Creates Corretto test worker `index`, or resets it to a fresh clone of the
    # migrated spec database. The document holds `database`, `migration_url`
    # and `runtime_url`.
    def test_worker(id : String, index : Int32) : JSON::Any
      validate_id(id)
      request("POST", "/v1/sites/#{id}/test-workers/#{index}", "{}")["worker"]
    end

    def drop_test_worker(id : String, index : Int32) : Nil
      validate_id(id)
      request("DELETE", "/v1/sites/#{id}/test-workers/#{index}")
      nil
    end

    def site_directory(id : String) : String
      validate_id(id)
      Latte::StateSecurity.validate_owned_directory(@runtime)
      sites = Latte::StateSecurity.ensure_owned_directory(File.join(@runtime, "sites"))
      Latte::StateSecurity.ensure_owned_directory(File.join(sites, id))
    end

    def site_log_directory(id : String, *, create : Bool) : String?
      validate_id(id)
      path = File.join(@root, "logs", "sites", id)
      if create
        Latte::StateSecurity.ensure_owned_directory(path)
      elsif File.info?(path, follow_symlinks: false)
        Latte::StateSecurity.validate_owned_directory(path)
        path
      end
    rescue ArgumentError
      raise Error.new("Site logs must be a private owned directory: #{path}")
    end

    def with_site_lock(id : String, name : String, & : -> T) : T forall T
      directory = site_directory(id)
      lock_path = File.join(directory, "dev.lock")
      if info = File.info?(lock_path, follow_symlinks: false)
        unless info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64 && info.permissions.value == 0o600
          raise Error.new("Development lock must be an owned private file")
        end
      end
      File.open(lock_path, "a+", perm: 0o600) do |lock|
        begin
          lock.flock_exclusive(blocking: false)
        rescue IO::Error
          raise Error.new("A development session is already running for #{name}")
        end
        yield
      end
    end

    private def validate_id(id : String) : Nil
      raise Error.new("Invalid Latte site identifier") unless Latte::StateSecurity.valid_site_id?(id)
    end

    private def service_states(document : JSON::Any) : Array(String)
      %w(postgres dns proxy).map { |name| document["services"][name]["state"].as_s }
    rescue KeyError | TypeCastError
      raise Error.new("Latte returned an invalid service status")
    end

    def request(method : String, path : String, body : String? = nil) : JSON::Any
      begin
        Latte::StateSecurity.validate_owned_directory(@root)
        Latte::StateSecurity.validate_owned_directory(@runtime)
        Latte::StateSecurity.validate_socket_entry(@socket_path, require_socket: true)
      rescue ex : ArgumentError
        raise Error.new("Latte is unavailable: #{ex.message}. Start Latte and try again.")
      end
      socket = Socket.unix
      socket.connect(Socket::UNIXAddress.new(@socket_path), timeout: 1.second)
      socket.read_timeout = 13.seconds
      socket.write_timeout = 2.seconds
      finished = false
      spawn do
        sleep 15.seconds
        socket.close unless finished || socket.closed?
      rescue IO::Error
      end
      client = HTTP::Client.new(socket, "latte")
      headers = HTTP::Headers{"Content-Type" => "application/json", "Connection" => "close"}
      client.exec(method, path, headers, body) do |response|
        bytes = Bytes.new(MAX_RESPONSE + 1)
        size = response.body_io.read_greedy(bytes)
        raise Error.new("Latte response exceeded 1 MiB") if size > MAX_RESPONSE
        document = JSON.parse(String.new(bytes[0, size]))
        raise Error.new("Unsupported Latte API version") unless document["version"].as_i == 1
        if response.status_code >= 400
          raise Error.new(document["error"]["message"].as_s)
        end
        document
      end
    rescue JSON::ParseException | KeyError | TypeCastError
      raise Error.new("Latte returned an invalid response; check its installation")
    rescue IO::Error
      raise Error.new("Latte connection failed or timed out; check frappe services")
    ensure
      finished = true
      client.try(&.close)
      socket.try(&.close)
    end
  end
end
