require "./dev_command"
require "./dev_gateway"
require "./dev_files"
require "./tools"
require "./latte_client"
require "../latte/project_status"

module Caramel::Frappe
  class DevSession
    @compiler : DevCommand? = nil
    @application : DevCommand? = nil
    @application_socket : String? = nil
    @server : HTTP::Server? = nil
    @gateway : DevGateway
    @busy = false
    @stopping = false
    @registered = false
    @opened = false
    @files_failed = false
    @open_browser = false
    @retry_at : Time::Instant? = nil
    @binary : String? = nil
    @id : String
    @directory = ""
    @socket = ""

    def initialize(@project : Project, @tools : Tools, @client : LatteClient, @values : Hash(String, String), @output : IO = STDOUT, @error : IO = STDERR)
      @id = Latte::Site.id_for(@project.name, @project.root, @project.metadata.domain_suffix)
      secrets = @values.select { |key, _| key.matches?(/SECRET|PASSWORD|TOKEN|URL/) }.values
      @gateway = DevGateway.new(@project.origin, secrets)
    end

    def run(*, open_browser : Bool = true) : Nil
      @open_browser = open_browser
      @directory = @client.site_directory(@id)
      lock_path = File.join(@directory, "dev.lock")
      if info = File.info?(lock_path, follow_symlinks: false)
        unless info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64 && info.permissions.value == 0o600
          raise Error.new("Development lock must be an owned private file")
        end
      end
      File.open(lock_path, "a+", perm: 0o600) do |lock|
        begin
          lock.flock_exclusive(blocking: false)
        rescue IO::Error
          raise Error.new("A development session is already running for #{@project.name}")
        end
        begin
          run_owned
        ensure
          shutdown
        end
      end
    end

    private def run_owned : Nil
      remove_stale_sockets
      @socket = File.join(@directory, "dev-#{Random::Secure.hex(4)}.sock")
      server = HTTP::Server.new([@gateway])
      @server = server
      server.bind_unix(@socket)
      File.chmod(@socket, 0o600)
      spawn do
        server.listen
      rescue ex
        @error.puts("Development listener stopped (#{ex.class})") unless @stopping
        @stopping = true
      end
      Signal::INT.trap { @stopping = true }
      Signal::TERM.trap { @stopping = true }
      Latte::ProjectStatus.write_session(@directory, @socket, @gateway.owner_token)
      # A response can fail after Latte persisted the route. Cleanup uses the
      # exact socket comparison even when registration's outcome is uncertain.
      @registered = true
      @client.set_upstream(@id, @socket)
      files = DevFiles.new(@project.root)
      files.publish_assets
      observed = files.snapshot
      pending : String? = observed.source
      changed_at = Time.instant - 1.second
      @output.puts("Watching #{@project.name} at #{@project.origin}. Ctrl-C stops this project.")
      @output.flush
      until @stopping
        begin
          current = files.snapshot
          if current.source != observed.source
            pending = current.source
            changed_at = Time.instant
            @retry_at = nil
            @gateway.building
            @compiler.try(&.stop)
          end
          if current.assets != observed.assets
            files.publish_assets
            current = files.snapshot
            @gateway.assets_changed
          end
          observed = current
          if @files_failed
            pending = current.source
            changed_at = Time.instant - 1.second
            @files_failed = false
          end
          if !@busy && (source = pending) && Time.instant - changed_at >= 200.milliseconds
            pending = nil
            launch_build(source, files)
          elsif !@busy && (retry_at = @retry_at) && Time.instant >= retry_at && (binary = @binary)
            @retry_at = nil
            launch_boot(binary)
          end
          if !@busy && @gateway.state == "ready" && (application = @application) && !application.running?
            @gateway.failed("Application exited. Fix the problem and save a source file to restart.\n#{application.output.contents}")
          end
        rescue ex
          @files_failed = true
          @gateway.failed("Development files need attention: #{ex.message}") unless @gateway.state == "failed"
        end
        sleep 100.milliseconds
      end
    end

    private def launch_build(source : String, files : DevFiles) : Nil
      @busy = true
      spawn do
        begin
          build(source, files)
        rescue ex
          @gateway.failed("Development build failed: #{ex.message}") unless @stopping
        ensure
          @busy = false
        end
      end
    end

    private def launch_boot(binary : String) : Nil
      @busy = true
      spawn do
        begin
          boot(binary)
        rescue ex
          @gateway.failed("Application startup failed: #{ex.message}") unless @stopping
        ensure
          @busy = false
        end
      end
    end

    private def build(fingerprint : String, files : DevFiles) : Nil
      @gateway.building
      started = Time.instant
      current = Project.load(@project.root)
      unless current.origin == @project.origin && current.local_environment == @values
        @gateway.failed("Project environment changed. Stop and restart frappe dev to load the new configuration.")
        return
      end
      directory = Latte::StateSecurity.ensure_owned_directory(File.join(@project.root, ".caramel/dev"))
      binary = File.join(directory, "application-#{fingerprint[0, 16]}")
      metadata = File.join(directory, "build.json")
      cached = cached?(metadata, binary, fingerprint)
      unless cached
        temporary = File.join(directory, "building-#{Random::Secure.hex(8)}")
        begin
          @output.puts("Building #{@project.name}…")
          @output.flush
          command = DevCommand.new([File.join(@tools.framework_root, "scripts/crystal"), "build", @project.entrypoint, "-D", "caramel_development", "--error-trace", "-o", temporary], @tools.environment, @project.root, @error)
          @compiler = command
          deadline = Time.instant + 180.seconds
          while command.running? && !@stopping && Time.instant < deadline
            sleep 50.milliseconds
          end
          command.stop if command.running?
          @compiler = nil
          return if @stopping || files.snapshot.source != fingerprint
          unless command.status.try(&.success?)
            @gateway.failed(command.output.contents.empty? ? "Compiler stopped before completing. Save a source file to retry." : command.output.contents)
            return
          end
          reject_symlink(binary)
          {% if flag?(:darwin) %}
            reject_symlink(binary + ".dwarf")
            raise Error.new("Compiler did not produce development debug information") unless File.file?(temporary + ".dwarf")
            File.rename(temporary + ".dwarf", binary + ".dwarf")
          {% end %}
          File.rename(temporary, binary)
          write_metadata(metadata, {source: fingerprint, binary: Digest::SHA256.hexdigest(File.read(binary)), debug: debug_checksum(binary), toolchain: @tools.toolchain.root, framework: Caramel::VERSION, mode: "caramel_development"}.to_json)
        ensure
          File.delete?(temporary)
          File.delete?(temporary + ".dwarf")
        end
      end
      @binary = binary
      return if @stopping || files.snapshot.source != fingerprint
      if boot(binary)
        elapsed = (Time.instant - started).total_milliseconds.round.to_i64
        @output.puts("Build ready#{cached ? " (cached)" : ""} in #{elapsed} ms · #{@project.origin}")
        @output.flush
        Dir.glob(File.join(directory, "application-*")).each do |old|
          File.delete(old) if old != binary && old != binary + ".dwarf" && File.basename(old).matches?(/\Aapplication-[0-9a-f]{16}(?:\.dwarf)?\z/) && File.file?(old) && !File.symlink?(old)
        end
      end
    end

    private def boot(binary : String) : Bool
      return false if @stopping
      socket = File.join(@directory, "app-#{Random::Secure.hex(4)}.sock")
      # Request serving receives only the runtime role, never migration/spec credentials.
      values = @values.reject { |key, _| key.starts_with?("SPEC_") || key == "MIGRATION_DATABASE_URL" }
      values.merge!({"CARAMEL_ENV" => "development", "CARAMEL_PROJECT_ROOT" => @project.root, "CARAMEL_SOCKET" => socket, "CARAMEL_EXPECTED_DATABASE_URL" => @values["DATABASE_URL"]})
      candidate = DevCommand.new([binary, "serve"], @tools.environment(values), @project.root, @output)
      accepted = false
      begin
        deadline = Time.instant + 20.seconds
        while candidate.running? && !@stopping && Time.instant < deadline
          if ready?(socket)
            previous, previous_socket = @application, @application_socket
            @application, @application_socket = candidate, socket
            @gateway.ready(socket)
            accepted = true
            previous.try(&.stop)
            File.delete?(previous_socket) if previous_socket
            if @open_browser && !@opened
              @opened = Process.run("/usr/bin/open", [@project.origin]).success?
              @error.puts("Could not open the browser. Visit #{@project.origin}.") unless @opened
            end
            return true
          end
          sleep 50.milliseconds
        end
        unless @stopping
          message = candidate.output.contents
          message = "Application did not become ready within 20 seconds. Check /health and terminal output." if message.empty?
          @gateway.failed(message)
          @retry_at = Time.instant + 1.second if message.includes?("Pending migrations")
        end
        false
      ensure
        unless accepted
          candidate.stop
          File.delete?(socket)
        end
      end
    end

    private def ready?(path : String) : Bool
      return false unless File.exists?(path)
      socket = Socket.unix
      socket.connect(Socket::UNIXAddress.new(path), timeout: 200.milliseconds)
      socket.read_timeout = 500.milliseconds
      client = HTTP::Client.new(socket, @project.name + "." + @project.metadata.domain_suffix)
      response = client.get("/health", HTTP::Headers{"Host" => URI.parse(@project.origin).authority.not_nil!, "Connection" => "close"})
      response.status_code == 200 && response.body == "ok"
    rescue IO::Error
      false
    ensure
      client.try(&.close)
      socket.try(&.close)
    end

    private def cached?(metadata : String, binary : String, fingerprint : String) : Bool
      reject_symlink(metadata)
      reject_symlink(binary)
      return false unless File.file?(metadata) && File.file?(binary)
      debug = debug_checksum(binary)
      {% if flag?(:darwin) %}
        return false unless debug
      {% end %}
      saved = JSON.parse(File.read(metadata))
      saved["source"].as_s == fingerprint && saved["binary"].as_s == Digest::SHA256.hexdigest(File.read(binary)) && saved["debug"].as_s? == debug && saved["toolchain"].as_s == @tools.toolchain.root && saved["framework"].as_s == Caramel::VERSION && saved["mode"].as_s == "caramel_development"
    rescue JSON::ParseException | KeyError | TypeCastError
      false
    end

    private def debug_checksum(binary : String) : String?
      {% if flag?(:darwin) %}
        path = binary + ".dwarf"
        reject_symlink(path)
        Digest::SHA256.hexdigest(File.read(path)) if File.file?(path)
      {% else %}
        nil
      {% end %}
    end

    private def write_metadata(path : String, contents : String) : Nil
      reject_symlink(path)
      temporary = File.tempfile("build-", dir: File.dirname(path))
      begin
        temporary << contents
        temporary.close
        File.rename(temporary.path, path)
      ensure
        temporary.close
        File.delete?(temporary.path)
      end
    end

    private def reject_symlink(path : String) : Nil
      if info = File.info?(path, follow_symlinks: false)
        raise Error.new("Development artifacts must be owned regular files") unless info.file? && !info.symlink? && info.owner_id.to_i64? == LibC.getuid.to_i64
      end
    end

    private def remove_stale_sockets : Nil
      Dir.children(@directory).each do |name|
        next unless name.matches?(/\A(?:dev|app)-[0-9a-f]{8}\.sock\z/)
        path = File.join(@directory, name)
        Latte::StateSecurity.validate_socket_entry(path, require_socket: true)
        deadline = Time.instant + 3.seconds
        loop do
          socket = Socket.unix
          begin
            socket.connect(Socket::UNIXAddress.new(path), timeout: 100.milliseconds)
          rescue ex : Socket::ConnectError
            raise ex unless ex.os_error == Errno::ECONNREFUSED || ex.os_error == Errno::ENOENT
            File.delete?(path)
            break
          ensure
            socket.close
          end
          raise Error.new("A live application still owns a private development socket; it was preserved") if Time.instant >= deadline
          sleep 100.milliseconds
        end
      end
    end

    private def shutdown : Nil
      @stopping = true
      @compiler.try(&.stop)
      deadline = Time.instant + 25.seconds
      while @busy && Time.instant < deadline
        sleep 50.milliseconds
      end
      @application.try(&.stop)
      if @registered
        begin
          @client.clear_upstream(@id, @socket)
        rescue ex
          @error.puts("Could not clear the stopped development route: #{ex.message}")
        end
      end
      @server.try { |server| server.close unless server.closed? }
      Latte::ProjectStatus.remove_session(@directory, @socket) unless @socket.empty?
      File.delete?(@socket) unless @socket.empty?
      File.delete?(@application_socket.not_nil!) if @application_socket
      Signal::INT.reset
      Signal::TERM.reset
    end
  end
end
