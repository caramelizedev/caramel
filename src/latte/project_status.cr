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

    def self.write_session(directory : String, socket : String, token : String) : Nil
      StateSecurity.validate_owned_directory(directory)
      raise ArgumentError.new("Invalid development session socket") unless File.dirname(socket) == directory
      raise ArgumentError.new("Invalid development session token") unless token.matches?(/\A[0-9a-f]{64}\z/)
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
      headers = HTTP::Headers{"Host" => site.domain, "X-Caramel-Owner-Token" => token, "Connection" => "close"}
      client.get("/__caramel/dev/status", headers) do |response|
        bytes = Bytes.new(4097)
        size = response.body_io.read_greedy(bytes)
        return result("unknown") unless response.status_code == 200 && size <= 4096
        document = JSON.parse(String.new(bytes[0, size]))
        case document["state"].as_s
        when "ready"    then result("running", "terminal")
        when "building" then result("building", "terminal")
        when "failed"   then result("build-error", "terminal")
        else                 result("unknown")
        end
      end
    rescue ex : Socket::ConnectError
      result(ex.os_error == Errno::ECONNREFUSED || ex.os_error == Errno::ENOENT ? "stopped" : "unavailable")
    rescue IO::Error
      result("unavailable")
    rescue ArgumentError | JSON::ParseException | KeyError | TypeCastError
      result("unknown")
    ensure
      finished = true
      client.try(&.close)
      socket.try(&.close)
    end

    private def self.result(state : String, owner : String? = nil)
      {state: state, owner: owner}
    end

    private def self.validate_file(path : String) : Nil
      info = File.info(path, follow_symlinks: false)
      unless info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64 && info.permissions.value == 0o600 && info.size <= 4096
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
