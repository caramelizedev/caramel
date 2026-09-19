require "./supervisor"

module Caramel::Latte
  class Daemon
    def initialize(@registry : Registry, @supervisor : Supervisor)
    end

    def run : Nil
      paths = @registry.paths
      lock_path = File.join(paths.run_dir, "daemon.lock")
      if info = File.info?(lock_path, follow_symlinks: false)
        unless info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64 && info.permissions.value == 0o600
          raise ArgumentError.new("Latte daemon lock is not a private owned file")
        end
      end
      File.open(lock_path, "a+", perm: 0o600) do |lock|
        begin
          lock.flock_exclusive(blocking: false)
        rescue IO::Error
          raise PublicError.new("already_running", "Latte is already running")
        end
        remove_stale_socket(paths.control_socket)
        server = Server.new(@registry, @supervisor)
        Signal::TERM.trap { server.close }
        Signal::INT.trap { server.close }
        @supervisor.start_services
        @supervisor.monitor
        server.listen
        # Daemon shutdown releases only IPC. Managed shared services survive
        # and are adopted on restart. Explicit Stop Services stops those too.
      end
    ensure
      @supervisor.stop_monitor
    end

    private def remove_stale_socket(path : String) : Nil
      return unless File.info?(path, follow_symlinks: false)
      StateSecurity.validate_socket_entry(path, require_socket: true)
      socket = Socket.unix
      begin
        socket.connect(Socket::UNIXAddress.new(path), timeout: 200.milliseconds)
      rescue ex : Socket::ConnectError
        # Only a refused connection proves the owned filesystem entry is stale.
        raise ex unless ex.os_error == Errno::ECONNREFUSED || ex.os_error == Errno::ENOENT
        File.delete(path) if File.info?(path, follow_symlinks: false)
        return
      ensure
        socket.close
      end
      raise PublicError.new("already_running", "A Latte daemon already owns this socket")
    end
  end
end
