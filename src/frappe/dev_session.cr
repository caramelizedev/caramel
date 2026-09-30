require "./dev_command"
require "./dev_retirement"
require "./dev_gateway"
require "./dev_files"
require "./tools"
require "./latte_client"
require "./site_log"
require "../latte/project_status"
require "../latte/watcher"

module Caramel::Frappe
  class DevSession
    # Quiet time after the last source change before a check starts (ADR
    # 0012). A multi-file save that outlasts it only cancels a check.
    DEBOUNCE = 50.milliseconds

    @compiler : DevCommand? = nil
    @application : DevCommand? = nil
    @app_log : SiteLog? = nil
    @compiler_log : SiteLog? = nil
    @application_socket : String? = nil
    @application_binary : String? = nil
    @retirement = DevRetirement.new
    @cleanup_pending = false
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
    # The newest confirmed source fingerprint not yet handed to a build; while
    # set, any running check or build is obsolete.
    @pending : String? = nil
    @id : String
    @directory = ""
    @socket = ""

    # *runtime_url* replaces the application's DATABASE_URL, e.g. with a
    # Latte branch's runtime URL for `frappe dev --branch`.
    def initialize(@project : Project, @tools : Tools, @client : LatteClient, @values : Hash(String, String), @output : IO = STDOUT, @error : IO = STDERR, *, @runtime_url : String? = nil)
      @id = Latte::Site.id_for(@project.name, @project.root, @project.metadata.domain_suffix)
      secrets = @values.select { |key, _| key.matches?(/SECRET|PASSWORD|TOKEN|URL/) }.values
      @runtime_url.try { |url| secrets << url }
      @gateway = DevGateway.new(@project.origin, secrets)
    end

    def run(*, open_browser : Bool = true) : Nil
      @open_browser = open_browser
      @directory = @client.site_directory(@id)
      @client.with_site_lock(@id, @project.name) do
        open_logs
        begin
          run_owned
        ensure
          begin
            shutdown
          ensure
            close_logs
          end
        end
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity -- the watch loop, one branch per event
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
      Process.on_terminate { @stopping = true }
      Latte::ProjectStatus.write_session(@directory, @socket, @gateway.owner_token)
      # A response can fail after Latte persisted the route. Cleanup uses the
      # exact socket comparison even when registration's outcome is uncertain.
      @registered = true
      @client.set_upstream(@id, @socket)
      files = DevFiles.new(@project.root)
      # Watching starts before the first snapshot so no edit falls between them.
      watcher = Latte::Watcher.new(@project.root, DevFiles::WATCHED)
      begin
        files.publish_assets
        observed = files.snapshot
        @pending = observed.source
        changed_at = Time.instant - 1.second
        @output.puts("Watching #{@project.name} at #{@project.origin}. Ctrl-C stops this project.")
        @output.flush
        until @stopping
          @retirement.check!
          cleanup_binaries if @cleanup_pending && @retirement.empty?
          begin
            # Wake at the debounce deadline while a source change waits.
            wait = 100.milliseconds
            wait = (changed_at + DEBOUNCE - Time.instant).clamp(Time::Span.zero, wait) if !@busy && @pending
            # A kernel event is only a hint: hashing confirms a real change and
            # whether it touched sources, assets or both.
            if watcher.changed?(wait)
              current = files.snapshot
              if current.source != observed.source
                @pending = current.source
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
                @pending = current.source
                changed_at = Time.instant - 1.second
                @files_failed = false
              end
            end
            if !@busy && (source = @pending) && Time.instant - changed_at >= DEBOUNCE
              @pending = nil
              launch_build(source)
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
            sleep 100.milliseconds
          end
        end
      ensure
        watcher.close
      end
    end

    private def launch_build(source : String) : Nil
      @busy = true
      spawn do
        build(source)
      rescue ex
        @gateway.failed("Development build failed: #{ex.message}") unless @stopping
      ensure
        @busy = false
      end
    end

    private def launch_boot(binary : String) : Nil
      @busy = true
      spawn do
        if boot(binary, quiet: true)
          @output.puts("Application ready · #{@project.origin}")
          @output.flush
        end
      rescue ex
        @gateway.failed("Application startup failed: #{ex.message}") unless @stopping
      ensure
        @busy = false
      end
    end

    private def build(fingerprint : String) : Nil
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
        # Tier 1: semantic feedback before paying for code generation.
        checked = Time.instant
        command = compile(["--no-codegen"], "check")
        return if @stopping || @pending
        elapsed = (Time.instant - checked).total_milliseconds.round.to_i64
        unless command.status.try(&.success?)
          @gateway.failed(command.output.contents.empty? ? "Type check stopped before completing. Save a source file to retry." : command.output.contents)
          @output.puts("Type check failed in #{elapsed} ms")
          @output.flush
          return
        end
        @output.puts("Type check passed in #{elapsed} ms")
        temporary = File.join(directory, "building-#{Random::Secure.hex(8)}")
        begin
          @output.puts("Building #{@project.name}…")
          @output.flush
          command = compile(["-o", temporary], "build")
          return if @stopping || @pending
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
      return if @stopping || @pending
      if boot(binary)
        elapsed = (Time.instant - started).total_milliseconds.round.to_i64
        @output.puts("Build ready#{cached ? " (cached)" : ""} in #{elapsed} ms · #{@project.origin}")
        @output.flush
        cleanup_binaries
      end
    end

    # Runs the dev build command with *arguments* until it exits, the session
    # stops, a newer source change supersedes it, or 180 seconds pass.
    private def compile(arguments : Array(String), event : String) : DevCommand
      @compiler_log.try(&.mark("#{event} #{@project.name}"))
      command = DevCommand.new([File.join(@tools.framework_root, "scripts/crystal"), "build", @project.entrypoint, "-D", "caramel_development", "--error-trace"] + arguments, @tools.environment, @project.root, @error, log: @compiler_log)
      @compiler = command
      deadline = Time.instant + 180.seconds
      while command.running? && !@stopping && !@pending && Time.instant < deadline
        # Wakes as soon as the compiler exits; the timeout re-checks for a
        # stop or a newer change.
        select
        when command.finished.receive?
        when timeout(50.milliseconds)
        end
      end
      command.stop if command.running?
      @compiler = nil
      command
    end

    # A quiet boot retries a start that stopped on pending migrations. It does
    # not print or log that refusal again, and forwards the application's
    # output once it serves.
    # ameba:disable Metrics/CyclomaticComplexity -- readiness, handover and failure paths of one start
    private def boot(binary : String, quiet : Bool = false) : Bool
      return false if @stopping
      socket = File.join(@directory, "app-#{Random::Secure.hex(4)}.sock")
      # Request serving receives only the runtime role, never migration/spec credentials.
      values = @values.reject { |key, _| key.starts_with?("SPEC_") || key == "MIGRATION_DATABASE_URL" }
      database = @runtime_url || @values["DATABASE_URL"]
      values.merge!({"CARAMEL_ENV" => "development", "CARAMEL_PROJECT_ROOT" => @project.root, "CARAMEL_SOCKET" => socket, "DATABASE_URL" => database, "CARAMEL_EXPECTED_DATABASE_URL" => database})
      @app_log.try(&.mark("start #{@project.name}")) unless quiet
      candidate = DevCommand.new([binary, "serve"], @tools.environment(values), @project.root, quiet ? nil : @output, log: quiet ? nil : @app_log)
      accepted = false
      begin
        deadline = Time.instant + 20.seconds
        while candidate.running? && !@stopping && Time.instant < deadline
          if ready?(socket)
            if quiet
              @app_log.try(&.mark("start #{@project.name}"))
              candidate.output.forward = @output
              candidate.output.log = @app_log
            end
            previous, previous_socket = @application, @application_socket
            @application, @application_socket = candidate, socket
            @application_binary = binary
            @gateway.ready(socket)
            # ameba:disable Lint/UselessAssign -- read by the ensure below
            accepted = true
            if previous
              @retirement.retire(previous) do
                if previous_path = previous_socket
                  File.delete?(previous_path)
                end
                cleanup_binaries
              end
            end
            if @open_browser && !@opened
              @opened = Process.run("/usr/bin/open", [@project.origin]).success?
              @error.puts("Could not open the browser. Visit #{@project.origin}.") unless @opened
            end
            return true
          end
          sleep 10.milliseconds
        end
        unless @stopping
          message = candidate.output.contents
          message = "Application did not become ready within 20 seconds. Check /health and terminal output." if message.empty?
          @gateway.failed(message)
          if message.includes?("Pending migrations")
            @retry_at = Time.instant + 1.second
          elsif quiet
            # A retry that fails for another reason shows why, as a first start does.
            @output.puts(message.chomp)
            @output.flush
          end
        end
        false
      ensure
        unless accepted
          candidate.stop
          File.delete?(socket)
        end
      end
    end

    private def cleanup_binaries : Nil
      # A retiring app may still need its debug file for an in-flight request.
      unless @retirement.empty?
        @cleanup_pending = true
        return
      end
      @cleanup_pending = false
      keep = [@binary, @application_binary].compact
      Dir.glob(File.join(@project.root, ".caramel/dev/application-*")).each do |old|
        next if keep.any? { |binary| old == binary || old == binary + ".dwarf" }
        File.delete(old) if File.basename(old).matches?(/\Aapplication-[0-9a-f]{16}(?:\.dwarf)?\z/) && File.file?(old) && !File.symlink?(old)
      end
    end

    private def ready?(path : String) : Bool
      return false unless File.exists?(path)
      socket = Socket.unix
      socket.connect(Socket::UNIXAddress.new(path), timeout: 200.milliseconds)
      socket.read_timeout = 500.milliseconds
      client = HTTP::Client.new(socket, @project.name + "." + @project.metadata.domain_suffix)
      authority = URI.parse(@project.origin).authority || raise Error.new("#{@project.name} has no HTTPS origin")
      response = client.get("/health", HTTP::Headers{"Host" => authority, "Connection" => "close"})
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
        raise Error.new("Development artifacts must be owned regular files") unless Latte::StateSecurity.owned_file?(info)
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

    private def open_logs : Nil
      directory = @client.site_log_directory(@id, create: true) || raise Error.new("Site logs are unavailable for #{@project.name}")
      @app_log = SiteLog.new(File.join(directory, "app.log"), @error)
      @compiler_log = SiteLog.new(File.join(directory, "compiler.log"), @error)
    end

    private def close_logs : Nil
      @app_log.try(&.close)
      @compiler_log.try(&.close)
    end

    private def shutdown : Nil
      @stopping = true
      @compiler.try(&.stop)
      deadline = Time.instant + 25.seconds
      while @busy && Time.instant < deadline
        sleep 50.milliseconds
      end
      @application.try(&.stop)
      @retirement.drain
      cleanup_binaries
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
      @application_socket.try { |socket| File.delete?(socket) }
      Signal::INT.reset
      Signal::TERM.reset
      Signal::HUP.reset
    end
  end
end
