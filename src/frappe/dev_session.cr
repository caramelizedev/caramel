require "./dev_command"
require "./dev_retirement"
require "./dev_gateway"
require "./dev_files"
require "./build_slot"
require "./tools"
require "./latte_client"
require "./site_log"
require "./dev_events"
require "./diagnostics"
require "../caramel/crema/editor"
require "../caramel/crema/redact"
require "../latte/project_status"
require "../latte/watcher"

module Caramel::Frappe
  class DevSession
    # Quiet time after the last source change before a check starts (ADR
    # 0012). A multi-file save that outlasts it only cancels a check.
    DEBOUNCE = 50.milliseconds

    # The names of dev builds and their debug files: cleanup deletes only these.
    DEV_BINARY = /\Aapplication-[0-9a-f]{16}(?:\.dwarf)?\z/

    NOT_READY = "Application did not become ready within 20 seconds. " \
                "Check /health and terminal output."
    LIVE_SOCKET = "A live application still owns a private development socket; " \
                  "it was preserved"

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
    @events : DevEvents? = nil
    @log_directory = ""
    @application_ops : String? = nil
    @secrets : Array(String)
    @editor_setting : String

    # *runtime_url* replaces the application's DATABASE_URL, e.g. with a
    # Latte branch's runtime URL for `frappe dev --branch`.
    def initialize(@project : Project,
                   @tools : Tools,
                   @client : LatteClient,
                   @values : Hash(String, String),
                   @output : IO = STDOUT,
                   @error : IO = STDERR, *,
                   @runtime_url : String? = nil)
      @id = Latte::Site.id_for(@project.name, @project.root, @project.metadata.domain_suffix)
      @secrets = @values.select { |key, _| key.matches?(/SECRET|PASSWORD|TOKEN|URL/) }.values
      @runtime_url.try { |url| @secrets << url }
      @editor_setting = ENV["CARAMEL_EDITOR"]? || @values["CARAMEL_EDITOR"]? || "zed"
      editor = Crema::Editor.from(@editor_setting)
      @gateway = DevGateway.new(@project.origin, @secrets, editor, @project.root)
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
      start_events
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
            if !@busy && @pending
              wait = (changed_at + DEBOUNCE - Time.instant).clamp(Time::Span.zero, wait)
            end
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
            report_exit if !@busy && @gateway.state == "ready"
          rescue ex
            @files_failed = true
            unless @gateway.state == "failed"
              @gateway.failed("Development files need attention: #{ex.message}")
            end
            sleep 100.milliseconds
          end
        end
      ensure
        watcher.close
      end
    end

    # Fails the session when the application it serves has exited.
    private def report_exit : Nil
      application = @application || return
      return if application.running?
      contents = application.output.contents
      @gateway.failed("Application exited. Fix the problem and save a source file " \
                      "to restart.\n#{contents}")
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
        @gateway.failed("Project environment changed. Stop and restart frappe dev to " \
                        "load the new configuration.")
        return
      end
      builds = File.join(@project.root, ".caramel/dev")
      directory = Latte::StateSecurity.ensure_owned_directory(builds)
      slot = BuildSlot.development(@project.root, fingerprint, @tools.toolchain.root)
      lock = BuildLock.new(@project.root)
      begin
        return unless acquired?(lock)
        cached = slot.holds?(fingerprint)
        return unless cached || compiled?(slot, directory, fingerprint)
      ensure
        lock.release
      end
      binary = slot.binary
      @binary = binary
      return if @stopping || @pending
      if boot(binary)
        elapsed = (Time.instant - started).total_milliseconds.round.to_i64
        label = cached ? " (cached)" : ""
        @output.puts("Build ready#{label} in #{elapsed} ms · #{@project.origin}")
        @output.flush
        cleanup_binaries
      end
    end

    # Builds and installs *fingerprint* into *slot*; false when the build
    # fails, a newer change supersedes it, or the session stops. The build's
    # semantic phase is Tier 1 (ADR 0012): a type error stops it before code
    # generation, and a pass is reported as soon as the compiler says so.
    private def compiled?(slot : BuildSlot, directory : String, fingerprint : String) : Bool
      started = Time.instant
      checked = false
      temporary = File.join(directory, "building-#{Random::Secure.hex(8)}")
      begin
        command = compile(["-o", temporary]) do
          checked = true
          type_checked(started)
        end
        return false if @stopping || @pending
        unless command.status.try(&.success?)
          compile_failed(command, checked, started)
          return false
        end
        # A compiler that reports no stages has still passed its type check.
        type_checked(started) unless checked
        slot.install(temporary, fingerprint)
        record_build("built", started)
        true
      ensure
        File.delete?(temporary)
        File.delete?(temporary + ".dwarf")
      end
    end

    # Shows the compiler's diagnostics in the browser and records the failed build.
    private def compile_failed(command : DevCommand,
                               checked : Bool,
                               started : Time::Instant) : Nil
      what = checked ? "Compiler" : "Type check"
      stopped = "#{what} stopped before completing."
      diagnostics = Diagnostics.parse(command.output.contents, @project.root, @project.entrypoint)
      @gateway.failed(failure(command, stopped), diagnostics)
      record_build("failed", started, command, diagnostics)
      return if checked

      elapsed = (Time.instant - started).total_milliseconds.round.to_i64
      @output.puts("Type check failed in #{elapsed} ms")
      @output.flush
    end

    # Tier 1 passed: the compiler finished its semantic stages and is
    # generating code.
    private def type_checked(started : Time::Instant) : Nil
      elapsed = (Time.instant - started).total_milliseconds.round.to_i64
      @output.puts("Type check passed in #{elapsed} ms")
      @compiler_log.try(&.mark("build #{@project.name}"))
      @output.puts("Building #{@project.name}…")
      @output.flush
      record_build("passed", started)
    end

    # Tells the inspector and the event log how a build or type check ended. Compiler
    # text is kept, redacted, only when no diagnostic could be read from it.
    private def record_build(state : String,
                             started : Time::Instant,
                             command : DevCommand? = nil,
                             diagnostics : Array(Diagnostic) = [] of Diagnostic) : Nil
      events = @events || return
      elapsed = (Time.instant - started).total_milliseconds.round(3)
      event = Crema::BuildEvent.new(Time.utc.to_rfc3339(fraction_digits: 3), state, elapsed)
      event.diagnostics = diagnostics.map { |item| build_diagnostic(item) }
      if command && diagnostics.empty?
        event.message = Crema::Redact.text(command.output.contents, @secrets, 32_768)
      end
      events.build(event)
    end

    private def build_diagnostic(item : Diagnostic) : Crema::BuildDiagnostic
      Crema::BuildDiagnostic.new(item.code, item.file, item.line, item.column,
        Crema::Redact.text(item.message, @secrets, 4096), item.remediation)
    end

    # Takes the build lock, waiting while a command builds (ADR 0013 §5);
    # false when the session stops or a newer change arrives first.
    private def acquired?(lock : BuildLock) : Bool
      return true if lock.acquire?
      @output.puts("Waiting for another build of #{@project.name}…")
      @output.flush
      until lock.acquire?
        return false if @stopping || @pending
        sleep 100.milliseconds
      end
      true
    end

    # What a failed compiler run printed, or *stopped* when it printed nothing.
    private def failure(command : DevCommand, stopped : String) : String
      contents = command.output.contents
      contents.empty? ? "#{stopped} Save a source file to retry." : contents
    end

    # Runs the dev build with *arguments* and yields once, when its type
    # check passes, unless the build became obsolete first.
    private def compile(arguments : Array(String), &) : DevCommand
      @compiler_log.try(&.mark("check #{@project.name}"))
      crystal = File.join(@tools.framework_root, "scripts/crystal")
      flags = ["-D", "caramel_development", "--error-trace", "--stats"]
      command_line = [crystal, "build", @project.entrypoint, *flags] + arguments
      command = DevCommand.new(command_line, @tools.environment, @project.root, @error,
        log: @compiler_log, stages: true)
      @compiler = command
      reported = watch(command) { yield }
      command.stop if command.running?
      @compiler = nil
      # The compiler may pass its type check and exit between two wakes.
      yield if !reported && command.checked? && !@stopping && !@pending
      command
    end

    # Waits until *command* exits, the session stops, a newer source change
    # supersedes it, or 360 seconds pass (the check and the build each had
    # 180 before they became one command). Yields once, when the type check
    # passes, and returns whether it did.
    private def watch(command : DevCommand, &) : Bool
      deadline = Time.instant + 360.seconds
      reported = false
      # Each wait wakes as soon as the compiler exits or reports; the timeout
      # re-checks for a stop or a newer change.
      while !reported && current?(command, deadline)
        select
        when command.finished.receive?
        when command.checked.receive?
          reported = true
          yield
        when timeout(50.milliseconds)
        end
      end
      while current?(command, deadline)
        select
        when command.finished.receive?
        when timeout(50.milliseconds)
        end
      end
      reported
    end

    private def current?(command : DevCommand, deadline : Time::Instant) : Bool
      command.running? && !@stopping && !@pending && Time.instant < deadline
    end

    # A quiet boot retries a start that stopped on pending migrations. It does
    # not print or log that refusal again, and forwards the application's
    # output once it serves.
    # ameba:disable Metrics/CyclomaticComplexity -- readiness, handover and failure paths
    private def boot(binary : String, quiet : Bool = false) : Bool
      return false if @stopping
      socket = File.join(@directory, "app-#{Random::Secure.hex(4)}.sock")
      ops = File.join(@directory, "ops-#{Random::Secure.hex(4)}.sock")
      # Request serving receives only the runtime role, never migration/spec credentials.
      values = @values.reject do |key, _|
        key.starts_with?("SPEC_") || key == "MIGRATION_DATABASE_URL"
      end
      database = @runtime_url || @values["DATABASE_URL"]
      values.merge!({
        "CARAMEL_ENV"                   => "development",
        "CARAMEL_PROJECT_ROOT"          => @project.root,
        "CARAMEL_SOCKET"                => socket,
        "CARAMEL_OPS_SOCKET"            => ops,
        "CARAMEL_EDITOR"                => @editor_setting,
        "DATABASE_URL"                  => database,
        "CARAMEL_EXPECTED_DATABASE_URL" => database,
      })
      @events.try { |events| values["CARAMEL_DEV_EVENTS"] = events.socket }
      @app_log.try(&.mark("start #{@project.name}")) unless quiet
      candidate = DevCommand.new([binary, "serve"],
        @tools.environment(values),
        @project.root,
        quiet ? nil : @output,
        log: quiet ? nil : @app_log)
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
            previous_ops = @application_ops
            @application, @application_socket = candidate, socket
            @application_ops = ops
            @application_binary = binary
            @gateway.ready(socket)
            # ameba:disable Lint/UselessAssign -- read by the ensure below
            accepted = true
            if previous
              @retirement.retire(previous) do
                previous_socket.try { |path| File.delete?(path) }
                previous_ops.try { |path| File.delete?(path) }
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
          message = NOT_READY if message.empty?
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
          File.delete?(ops)
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
        next unless File.basename(old).matches?(DEV_BINARY)
        File.delete(old) if File.file?(old) && !File.symlink?(old)
      end
    end

    private def ready?(path : String) : Bool
      return false unless File.exists?(path)
      socket = Socket.unix
      socket.connect(Socket::UNIXAddress.new(path), timeout: 200.milliseconds)
      socket.read_timeout = 500.milliseconds
      client = HTTP::Client.new(socket, @project.name + "." + @project.metadata.domain_suffix)
      authority = URI.parse(@project.origin).authority
      raise Error.new("#{@project.name} has no HTTPS origin") unless authority
      response = client.get("/health", HTTP::Headers{"Host" => authority, "Connection" => "close"})
      response.status_code == 200 && response.body == "ok"
    rescue IO::Error
      false
    ensure
      client.try(&.close)
      socket.try(&.close)
    end

    private def remove_stale_sockets : Nil
      Dir.children(@directory).each do |name|
        next unless name.matches?(/\A(?:dev|app|ops|events)-[0-9a-f]{8}\.sock\z/)
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
          raise Error.new(LIVE_SOCKET) if Time.instant >= deadline
          sleep 100.milliseconds
        end
      end
    end

    private def open_logs : Nil
      directory = @client.site_log_directory(@id, create: true)
      raise Error.new("Site logs are unavailable for #{@project.name}") unless directory
      @log_directory = directory
      @app_log = SiteLog.new(File.join(directory, "app.log"), @error)
      @compiler_log = SiteLog.new(File.join(directory, "compiler.log"), @error)
    end

    # Listens for the application's trace and error events, which the inspector shows.
    private def start_events : Nil
      events = DevEvents.new(@directory, @log_directory, @error)
      events.start
      @client.collector_port.try { |port| events.forward(port, @project.name) }
      @events = events
      @gateway.collected = across_lookup
      @gateway.events = events
    end

    # Asks Latte's collector for the spans of other services in a trace.
    private def across_lookup : Crema::CollectedLookup
      client, project = @client, @project.name
      ->(trace_id : String) { Crema::Render.across(client.collected(trace_id), project) }
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
      @application_ops.try { |path| File.delete?(path) }
      @events.try(&.close)
      Signal::INT.reset
      Signal::TERM.reset
      Signal::HUP.reset
    end
  end
end
