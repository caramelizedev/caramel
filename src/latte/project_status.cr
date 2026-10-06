require "http/client"
require "socket/unix_socket"
require "json"
require "./paths"
require "./site"

module Caramel::Latte
  # Session metadata contains only the current private socket and a separate
  # owner-IPC token. State is queried live; a stale file never proves liveness.
  module ProjectStatus
    FILE_NAME = "dev-session.json"

    # The newest error the development application reported since `frappe dev` started.
    record LastError,
      fingerprint : String,
      error_class : String,
      location : String?,
      at : String do
      include JSON::Serializable
    end

    def self.write_session(directory : String, socket : String, token : String) : Nil
      StateSecurity.validate_owned_directory(directory)
      unless File.dirname(socket) == directory
        raise ArgumentError.new("Invalid development session socket")
      end
      unless token.matches?(/\A[0-9a-f]{64}\z/)
        raise ArgumentError.new("Invalid development session token")
      end
      path = File.join(directory, FILE_NAME)
      validate_file(path) if File.info?(path, follow_symlinks: false)
      temporary = File.tempfile("session-", dir: directory)
      begin
        temporary.chmod(0o600)
        temporary << {version: 1, socket: socket, token: token}.to_json
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, path)
      ensure
        temporary.close
        File.delete?(temporary.path)
      end
    end

    def self.remove_session(directory : String, socket : String) : Bool
      StateSecurity.validate_owned_directory(directory)
      path = File.join(directory, FILE_NAME)
      return false unless File.info?(path, follow_symlinks: false)
      saved = session(path)
      return false unless saved["socket"].as_s == socket
      File.delete(path)
      true
    end

    # ameba:disable Metrics/CyclomaticComplexity -- validates each status source separately
    def self.read(paths : Paths, site : Site)
      path = site.upstream
      return result("stopped") unless path && File.info?(path, follow_symlinks: false)
      StateSecurity.validate_socket_entry(path, require_socket: true)
      socket = Socket.unix
      socket.connect(Socket::UNIXAddress.new(path), timeout: 100.milliseconds)
      directory = File.join(paths.run_dir, "sites", site.id)
      manifest = File.join(directory, FILE_NAME)
      return result("running") unless File.info?(manifest, follow_symlinks: false)
      StateSecurity.validate_owned_directory(directory)
      saved = session(manifest)
      return result("unknown") unless saved["socket"].as_s == path
      token = saved["token"].as_s
      socket.read_timeout = 250.milliseconds
      socket.write_timeout = 100.milliseconds
      finished = false
      spawn do
        sleep 500.milliseconds
        socket.close unless finished || socket.closed?
      rescue IO::Error
      end
      client = HTTP::Client.new(socket, site.domain)
      headers = HTTP::Headers{
        "Host"                  => site.domain,
        "X-Caramel-Owner-Token" => token,
        "Connection"            => "close",
      }
      client.get("/__caramel/dev/status", headers) do |response|
        bytes = Bytes.new(4097)
        size = response.body_io.read_greedy(bytes)
        return result("unknown") unless response.status_code == 200 && size <= 4096
        document = JSON.parse(String.new(bytes[0, size]))
        errors, last_error = errors_of(document)
        case document["state"].as_s
        when "ready"    then result("running", "terminal", errors, last_error)
        when "building" then result("building", "terminal", errors, last_error)
        when "failed"   then result("build-error", "terminal", errors, last_error)
        else                 result("unknown")
        end
      end
    rescue ex : Socket::ConnectError
      stopped = ex.os_error == Errno::ECONNREFUSED || ex.os_error == Errno::ENOENT
      result(stopped ? "stopped" : "unavailable")
    rescue IO::Error
      result("unavailable")
    rescue ArgumentError | JSON::ParseException | KeyError | TypeCastError
      result("unknown")
    ensure
      finished = true
      client.try(&.close)
      socket.try(&.close)
    end

    private def self.result(state : String,
                            owner : String? = nil,
                            errors : Int32 = 0,
                            last_error : LastError? = nil)
      {state: state, owner: owner, errors: errors, last_error: last_error}
    end

    # The error count and newest error a gateway reports. A gateway that predates them
    # reports none.
    private def self.errors_of(document : JSON::Any) : {Int32, LastError?}
      count = (document["errors"]?.try(&.as_i64?) || 0_i64).clamp(0_i64, Int32::MAX.to_i64).to_i
      newest = document["last_error"]?
      last = newest.try { |error| error.as_h? ? LastError.from_json(error.to_json) : nil }
      {count, last}
    rescue JSON::SerializableError | OverflowError | TypeCastError
      {0, nil}
    end

    private def self.validate_file(path : String) : Nil
      info = File.info(path, follow_symlinks: false)
      unless StateSecurity.private_file?(info) && info.size <= 4096
        raise ArgumentError.new("Development session metadata must be an owned private file")
      end
    end

    private def self.session(path : String) : JSON::Any
      validate_file(path)
      value = JSON.parse(File.read(path))
      unless value["version"].as_i == 1 && value["token"].as_s.matches?(/\A[0-9a-f]{64}\z/)
        raise ArgumentError.new("Invalid development session metadata")
      end
      value
    end
  end
end
