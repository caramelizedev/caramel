require "./server"
require "./postgres"
require "./dns"
require "./proxy"
require "./collector"
require "./deadline"
require "./logs"
require "openssl"

module Caramel::Latte
  # One owner for shared services. Slow lifecycle operations run behind the IPC
  # response; status always remains available to the menu application.
  class Supervisor < ServiceControl
    BUSY            = "A service operation is already in progress"
    NOT_READY       = "Start Latte services and wait for them to be ready"
    NOT_PROVISIONED = "Project has no provisioned database; run frappe setup"
    WORKER_FAILED   = "Test worker database operation failed"

    getter postgres : Postgres
    getter dns : DNS
    getter proxy : Proxy
    getter collector : Collector
    @states = {"postgres" => "stopped", "dns" => "stopped", "proxy" => "stopped"}
    @error : String? = nil
    @busy = false
    @recovery_attempted = false
    @monitoring = false
    @readiness_misses = {"dns" => 0, "proxy" => 0}
    @configuration : String? = nil
    @lock = Mutex.new
    @dns_child : ManagedChild
    @proxy_child : ManagedChild

    def initialize(@registry : Registry,
                   @toolchain : Toolchain = Toolchain.for_checkout,
                   dns_port : Int32 = 15353,
                   http_port : Int32 = 18080,
                   https_port : Int32 = 18443,
                   otlp_port : Int32 = Collector::DEFAULT_PORT)
      paths = @registry.paths
      @postgres = Postgres.new(paths, @toolchain)
      @dns = DNS.new(paths, dns_port)
      @proxy = Proxy.new(@registry, https_port, http_port, public_https_port: 443)
      @collector = Collector.new(otlp_port)
      @dns_child = ManagedChild.new(
        name: "dns",
        executable: @toolchain.coredns,
        args: ["-conf", @dns.config_file],
        record_path: File.join(paths.dns_dir, "process.json"),
        log_path: File.join(paths.logs_dir, "dns.log"),
        environment: @toolchain.environment,
      )
      environment = @toolchain.environment
      @proxy.environment.each { |key, value| environment[key] = value }
      @proxy_child = ManagedChild.new(
        name: "proxy",
        executable: @toolchain.caddy,
        args: ["run", "--config", @proxy.config_file],
        record_path: File.join(paths.caddy_dir, "process.json"),
        log_path: File.join(paths.logs_dir, "proxy.log"),
        environment: environment,
      )
    end

    def status_json(version : Int32 = 1) : String
      status = {
        version:  version,
        latte:    Caramel::VERSION,
        api:      ControlAPI::VERSIONS,
        services: @states.transform_values { |state| {state: state} },
        error:    @error,
      }
      return status.to_json if version < 2

      status.merge(collector: collector_status).to_json
    end

    # The traces the collector holds, newest first (control API 2).
    def traces_json(limit : Int32) : String
      {version: 2, traces: @collector.traces(limit)}.to_json
    end

    # The spans of one collected trace (control API 2).
    def trace_json(trace_id : String) : String
      spans = @collector.spans(trace_id)
      raise PublicError.new("not_found", "No such trace", 404) unless spans

      {version: 2, trace_id: trace_id, spans: spans}.to_json
    end

    private def collector_status
      {state: @collector.state, port: @collector.port, error: @collector.error}
    end

    def start_services : Nil
      @recovery_attempted = false
      begin_start
    end

    private def begin_start : Nil
      schedule("starting") do
        previous = {
          "postgres" => @postgres.running?,
          "dns"      => @dns_child.running?,
          "proxy"    => @proxy_child.running?,
        }
        begin
          @dns.write(@registry.list)
          @proxy.write
          @postgres.start
          @postgres.release_guards
          @states["postgres"] = "running"
          @dns_child.start
          wait_ready("DNS", 5.seconds) { child_ready?(@dns_child) { dns_ready? } }
          @states["dns"] = "running"
          @proxy_child.start
          wait_ready("HTTPS proxy control", 10.seconds) do
            child_ready?(@proxy_child) { admin_available? }
          end
          reconcile
          wait_ready("HTTPS proxy", 10.seconds) { proxy_ready? }
          @states["proxy"] = "running"
        rescue ex
          OperationDeadline.without do
            {"proxy" => @proxy_child, "dns" => @dns_child}.each do |name, child|
              begin
                child.stop if !previous[name] && child.running?
              rescue error
                STDERR.puts("Latte startup cleanup: #{error.class}")
              end
              @states[name] = "failed" unless previous[name]
            end
            begin
              @postgres.stop unless previous["postgres"]
            rescue error
              STDERR.puts("Latte database cleanup: #{error.class}")
            end
            @states["postgres"] = "failed" unless previous["postgres"]
          end
          raise ex
        end
      end
    end

    def stop_services : Nil
      schedule("stopping") do
        errors = false
        {"proxy" => @proxy_child, "dns" => @dns_child}.each do |name, child|
          child.stop if child.running?
          @states[name] = "stopped"
        rescue
          @states[name] = "failed"
          errors = true
        end
        begin
          @postgres.stop
          @states["postgres"] = "stopped"
        rescue
          @states["postgres"] = "failed"
          errors = true
        end
        message = "A managed service could not stop; check Latte logs"
        raise PublicError.new("stop_failed", message) if errors
      end
    end

    def await_idle(timeout : Time::Span = 90.seconds) : Nil
      deadline = Time.instant + timeout
      while @busy
        if Time.instant >= deadline
          raise PublicError.new("service_timeout", "Managed services exceeded their deadline")
        end
        sleep 20.milliseconds
      end
    end

    # Re-allows connections to every Caramel database a guard disabled. Runs at
    # daemon exit; startup releases them again after any crash.
    def release_guards : Nil
      @postgres.release_guards if @postgres.running?
    rescue ex
      STDERR.puts("Latte guard release: #{ex.class}: #{ex.message}")
    end

    def register(name : String, directory : String, suffix : String) : Site
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        site = @registry.register(name, directory, suffix)
        @postgres.provision(site)
        reconcile
        site
      end
    end

    def unregister(id : String) : Bool
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        removed = @registry.unregister(id)
        reconcile if removed
        !removed.nil?
      end
    end

    # Credentials are returned only on an explicit owner-IPC request bound to
    # the registered directory. Status/site summaries never contain them.
    def environment_json(id : String, directory : String) : String
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        site = @registry.find(id)
        raise PublicError.new("not_found", "Project is not registered", 404) unless site
        unless site.directory == Site.canonical_directory(directory)
          raise ArgumentError.new("Project directory differs from registration")
        end
        credentials = @postgres.credentials(site)
        {version: 1, environment: {
          DATABASE_URL:                credentials.development_runtime,
          MIGRATION_DATABASE_URL:      credentials.development_migration,
          SPEC_DATABASE_URL:           credentials.spec_runtime,
          SPEC_MIGRATION_DATABASE_URL: credentials.spec_migration,
        }}.to_json
      end
    end

    def create_branch_json(id : String, name : String) : String
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        branch = @postgres.create_branch(registered(id), name)
        created = {
          name:          branch.name,
          database:      branch.database,
          migration_url: branch.migration_url,
          runtime_url:   branch.runtime_url,
        }
        {version: 1, branch: created}.to_json
      end
    rescue Postgres::BranchExists
      raise PublicError.new("branch_exists", "Branch #{name} already exists; delete it first", 409)
    rescue Postgres::SecretMissing
      raise PublicError.new("not_provisioned", NOT_PROVISIONED, 409)
    rescue ex : Postgres::Error
      raise PublicError.new("branch_failed", ex.message || "Database branch operation failed")
    end

    def branches_json(id : String) : String
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        names = @postgres.list_branches(registered(id))
        branches = names.map do |name|
          {name: name, database: Postgres.branch_database(id, name)}
        end
        {version: 1, branches: branches}.to_json
      end
    end

    def drop_branch(id : String, name : String) : Bool
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        @postgres.drop_branch(registered(id), name)
      end
    rescue ex : Postgres::Error
      raise PublicError.new("branch_failed", ex.message || "Database branch operation failed")
    end

    # Creates, or resets to a fresh clone of the migrated spec database, the
    # site's Corretto test worker `index`.
    def test_worker_json(id : String, index : Int32) : String
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        worker = @postgres.reset_test_worker(registered(id), index)
        reset = {
          index:         index,
          database:      worker.database,
          migration_url: worker.migration_url,
          runtime_url:   worker.runtime_url,
        }
        {version: 1, worker: reset}.to_json
      end
    rescue Postgres::SecretMissing
      raise PublicError.new("not_provisioned", NOT_PROVISIONED, 409)
    rescue ex : Postgres::Error
      raise PublicError.new("test_worker_failed", ex.message || WORKER_FAILED)
    end

    def drop_test_worker(id : String, index : Int32) : Bool
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        @postgres.drop_test_worker(registered(id), index)
      end
    rescue ex : Postgres::Error
      raise PublicError.new("test_worker_failed", ex.message || WORKER_FAILED)
    end

    private def registered(id : String) : Site
      @registry.find(id) || raise PublicError.new("not_found", "Project is not registered", 404)
    end

    def set_upstream(id : String, socket : String) : Site
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        site = @registry.set_upstream(id, socket)
        reconcile
        site
      end
    end

    def reconcile : Nil
      @dns.write(@registry.list)
      # CoreDNS reloads the hosts file asynchronously. Do not publish a ready
      # registration or let monitoring consume recovery during that window.
      begin
        wait_ready("DNS configuration", 5.seconds) { child_ready?(@dns_child) { dns_ready? } }
      rescue ex
        @states["dns"] = "failed"
        @error = "Project DNS could not reload; use Start Services to retry"
        raise ex
      end
      @proxy.write
      config = @proxy.config_file
      address = "unix/#{@proxy.admin_socket}"
      reload = ["reload", "--config", config, "--address", address]
      result = @toolchain.run(:caddy, reload, timeout: 5.seconds)
      unless result.success?
        @states["proxy"] = "failed"
        message = "HTTPS routing could not reload; retry after checking Latte services"
        @error = message
        raise PublicError.new("proxy_reload_failed", message)
      end
      @configuration = File.read(@proxy.config_file)
    end

    def clear_upstream(id : String, socket : String) : Bool
      require_ready!
      @lock.synchronize do
        OperationDeadline.check!
        cleared = @registry.clear_upstream(id, socket)
        reconcile if cleared
        !cleared.nil?
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity -- one branch per service health state
    def monitor : Nil
      return if @monitoring
      @monitoring = true
      spawn do
        while @monitoring
          sleep 1.second
          break unless @monitoring
          begin
            Logs.sweep(@registry.paths)
          rescue ex
            STDERR.puts("Latte log retention: #{ex.class}")
          end
          next if @busy
          crashed = false
          @lock.synchronize do
            if @states["postgres"] == "running" && !@postgres.running?
              @states["postgres"] = "failed"
              crashed = true
            end
            if @states["dns"] == "running" && dns_down?
              @states["dns"] = "failed"
              crashed = true
            end
            if @states["proxy"] == "running"
              if proxy_down?
                @states["proxy"] = "failed"
                crashed = true
              else
                reconcile if @proxy.configuration != @configuration
              end
            end
          rescue ex
            @states["proxy"] = "failed"
            @error = "Service health check failed; use Start Services to retry"
            STDERR.puts("Latte health: #{ex.class}")
          end
          if crashed
            if @recovery_attempted
              @error = "A managed service failed after automatic recovery; " \
                       "use Start Services to retry"
            else
              @recovery_attempted = true
              begin_start
            end
          end
        end
      end
    end

    def stop_monitor : Nil
      @monitoring = false
    end

    private def dns_down? : Bool
      !@dns_child.running? || readiness_failed?("dns", dns_ready?)
    end

    private def proxy_down? : Bool
      !@proxy_child.running? || readiness_failed?("proxy", proxy_ready?)
    end

    private def schedule(state : String, &block : -> Nil) : Nil
      raise PublicError.new("services_busy", BUSY, 409) if @busy
      @busy = true
      @error = nil
      @readiness_misses.keys.each { |key| @readiness_misses[key] = 0 }
      @states.keys.each { |key| @states[key] = state }
      spawn do
        @lock.synchronize do
          OperationDeadline.run(state == "starting" ? 90.seconds : 60.seconds) { block.call }
        rescue ex
          @error = case ex
                   when PublicError, DeadlineExceeded, Postgres::Error,
                        Toolchain::Unavailable, Toolchain::VersionMismatch
                     ex.message || "Managed service operation failed"
                   else
                     "Managed service operation failed; check Latte logs"
                   end
          STDERR.puts("Latte services: #{ex.class}: #{@error}")
          @states.keys.each { |key| @states[key] = "failed" if @states[key] == state }
        ensure
          @busy = false
        end
      end
    end

    private def require_ready! : Nil
      if @busy || @states.values.any? { |state| state != "running" }
        raise PublicError.new("services_not_ready", NOT_READY, 409)
      end
    end

    private def wait_ready(name : String, timeout : Time::Span, &probe : -> Bool) : Nil
      deadline = Time.instant + OperationDeadline.limit(timeout)
      until probe.call
        OperationDeadline.check!
        if Time.instant >= deadline
          raise PublicError.new("service_timeout", "#{name} did not become ready")
        end
        sleep 50.milliseconds
      end
    end

    private def child_ready?(child : ManagedChild, &probe : -> Bool) : Bool
      unless child.running?
        message = "#{child.name} exited during startup; check Latte logs"
        raise PublicError.new("service_exited", message)
      end
      probe.call
    end

    private def dns_ready? : Bool
      sites = @registry.list
      return dns_query_ready?(nil) if sites.empty?
      sites.all? { |site| dns_query_ready?(site) }
    end

    private def readiness_failed?(name : String, ready : Bool) : Bool
      # Process death is handled immediately by the caller. A running service
      # gets three samples so one lost packet/slow request cannot spend its
      # single automatic recovery attempt.
      @readiness_misses[name] = ready ? 0 : @readiness_misses[name] + 1
      @readiness_misses[name] >= 3
    end

    private def dns_query_ready?(site : Site?) : Bool
      socket = UDPSocket.new
      socket.read_timeout = OperationDeadline.limit(200.milliseconds)
      socket.connect("127.0.0.1", @dns.port)
      query = IO::Memory.new
      query.write(Bytes[0x43, 0x41, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
      (site ? site.domain : "caramel").split('.').each do |label|
        query.write_byte(label.bytesize.to_u8)
        query << label
      end
      query.write(Bytes[0, 0, site ? 1_u8 : 6_u8, 0, 1])
      socket.send(query.to_slice)
      bytes = Bytes.new(512)
      count, _ = socket.receive(bytes)
      valid = count > 12 && dns_reply?(bytes)
      valid && (!site || loopback_answer?(bytes, count))
    rescue IO::Error
      false
    ensure
      socket.try(&.close)
    end

    # A response (QR set) without error (RCODE 0) to the query with id 0x4341.
    private def dns_reply?(bytes : Bytes) : Bool
      ours = bytes[0] == 0x43 && bytes[1] == 0x41
      ours && (bytes[2] & 0x80) != 0 && (bytes[3] & 0x0f) == 0
    end

    # At least one answer, and the reply ends with the address 127.0.0.1.
    private def loopback_answer?(bytes : Bytes, count : Int32) : Bool
      (bytes[6] != 0 || bytes[7] != 0) && bytes[count - 4, 4] == Bytes[127, 0, 0, 1]
    end

    private def proxy_ready? : Bool
      expected = File.read(@proxy.config_file)
      command = ["/usr/bin/curl", "--silent", "--fail", "--max-time", "1", "--noproxy", "*",
                 "--unix-socket", @proxy.admin_socket, "http://localhost/config/"]
      limit = expected.bytesize + 4096
      result = ProcessRunner.run(command, timeout: 2.seconds, output_limit: limit)
      return false unless result.success? && JSON.parse(result.stdout) == JSON.parse(expected)
      if site = @registry.list.first?
        return tls_ready?(site)
      end
      true
    rescue IO::Error | JSON::ParseException
      false
    end

    private def tls_ready?(site : Site) : Bool
      # Service health must not depend on the application's response time or
      # execute application routes. Check Caddy's certificate handshake only.
      timeout = OperationDeadline.limit(1.second)
      seconds = timeout.total_seconds
      socket = TCPSocket.new("127.0.0.1", @proxy.https_port, seconds, seconds)
      socket.read_timeout = timeout
      socket.write_timeout = timeout
      context = OpenSSL::SSL::Context::Client.new
      context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
      context.ca_certificates = @proxy.root_certificate
      tls = OpenSSL::SSL::Socket::Client.new(
        socket,
        context: context,
        hostname: site.domain,
        sync_close: true,
      )
      true
    rescue IO::Error | OpenSSL::SSL::Error
      false
    ensure
      tls.try(&.close)
      socket.try(&.close)
    end

    private def admin_available? : Bool
      socket = Socket.unix
      address = Socket::UNIXAddress.new(@proxy.admin_socket)
      socket.connect(address, timeout: OperationDeadline.limit(200.milliseconds))
      true
    rescue IO::Error
      false
    ensure
      socket.try(&.close)
    end
  end
end
