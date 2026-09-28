require "http/client"
require "./supervisor"

lib LibC
  fun setsid : PidT
end

module Caramel::Latte
  class Daemon
    def initialize(@registry : Registry, @supervisor : Supervisor)
    end

    # Moves this process into its own session, so closing the terminal that
    # started it or pressing Ctrl-C there does not stop Latte, and sends its
    # output to logs/latte.log. Fails harmlessly for a process group leader,
    # which a launchd job already is.
    def self.detach(paths : Paths) : Nil
      LibC.setsid
      log = File.join(paths.logs_dir, Paths::DAEMON_LOG)
      if info = File.info?(log, follow_symlinks: false)
        unless info.file? && info.owner_id.to_i64? == LibC.getuid.to_i64 && info.permissions.value == 0o600
          raise ArgumentError.new("Latte log is not a private owned file")
        end
      end
      output = File.open(log, "a", perm: 0o600)
      STDIN.reopen(File.open(File::NULL))
      STDOUT.reopen(output)
      STDERR.reopen(output)
      STDOUT.sync = true
      STDERR.sync = true
      output.close
    end

    # Whether a daemon holds the instance lock for *paths*.
    def self.running?(paths : Paths) : Bool
      lock_path = File.join(paths.run_dir, "daemon.lock")
      return false unless File.info?(lock_path, follow_symlinks: false)
      File.open(lock_path, "r") do |lock|
        lock.flock_exclusive(blocking: false)
        lock.flock_unlock
        false
      rescue IO::Error
        true
      end
    end

    # Asks the daemon for *paths* to exit and waits until it has. Services
    # keep running. Returns false when no daemon was running.
    def self.stop(paths : Paths, timeout : Time::Span = 20.seconds) : Bool
      return false unless running?(paths)
      socket = Socket.unix
      begin
        socket.connect(Socket::UNIXAddress.new(paths.control_socket), timeout: 2.seconds)
        socket.read_timeout = timeout
        HTTP::Client.new(socket, "latte").post("/v1/daemon/stop", HTTP::Headers{"Content-Type" => "application/json", "Connection" => "close"}, "{}")
      rescue ex : IO::Error
        raise PublicError.new("stop_failed", "Latte did not accept the stop request: #{ex.message}")
      ensure
        socket.close
      end
      deadline = Time.instant + timeout
      while running?(paths)
        raise PublicError.new("stop_failed", "Latte did not stop within #{timeout.total_seconds.to_i} seconds") if Time.instant >= deadline
        sleep 50.milliseconds
      end
      true
    end

    def run : Nil
      paths = @registry.paths
      lock_path = File.join(paths.run_dir, "daemon.lock")
      if info = File.info?(lock_path, follow_symlinks: false)
        unless StateSecurity.private_file?(info)
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
        Process.on_terminate { server.close }
        begin
          @supervisor.start_services
          @supervisor.monitor
          server.listen
        ensure
          # Exit abandons in-flight fibers, including a guarded clone whose
          # own release would never run.
          @supervisor.release_guards
        end
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
