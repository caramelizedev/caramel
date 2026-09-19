require "./server"
require "./postgres"
require "./dns"
require "./proxy"
require "./deadline"
require "./logs"
require "openssl"

module Caramel::Latte
  # One owner for shared services. Slow lifecycle operations run behind the IPC
  # response; status always remains available to the menu application.
  class Supervisor < ServiceControl
    getter postgres : Postgres
    getter dns : DNS
    getter proxy : Proxy
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

    def initialize(@registry : Registry, @toolchain : Toolchain = Toolchain.new,
                   dns_port : Int32 = 15353, http_port : Int32 = 18080, https_port : Int32 = 18443)
      paths = @registry.paths
      @postgres = Postgres.new(paths, @toolchain)
      @dns = DNS.new(paths, dns_port)
      @proxy = Proxy.new(@registry, https_port, http_port, public_https_port: 443)
      @dns_child = ManagedChild.new("dns", @toolchain.coredns, ["-conf", @dns.config_file],
        File.join(paths.dns_dir, "process.json"), File.join(paths.logs_dir, "dns.log"), @toolchain.environment)
      environment = @toolchain.environment
      @proxy.environment.each { |key, value| environment[key] = value }
      @proxy_child = ManagedChild.new("proxy", @toolchain.caddy, ["run", "--config", @proxy.config_file],
        File.join(paths.caddy_dir, "process.json"), File.join(paths.logs_dir, "proxy.log"), environment)
    end

    def status_json : String
      {version: 1, services: @states.transform_values { |state| {state: state} }, error: @error}.to_json
    end

    def start_services : Nil
      @recovery_attempted = false
      begin_start
    end

    private def begin_start : Nil
      schedule("starting") do
        previous = {"postgres" => @postgres.running?, "dns" => @dns_child.running?, "proxy" => @proxy_child.running?}
        begin
          @dns.write(@registry.list)
          @proxy.write
          @postgres.start
          @states["postgres"] = "running"
          @dns_child.start
          wait_ready("DNS", 5.seconds) { child_ready?(@dns_child) { dns_ready? } }
          @states["dns"] = "running"
          @proxy_child.start
          wait_ready("HTTPS proxy control", 10.seconds) { child_ready?(@proxy_child) { admin_available? } }
          reconcile
          wait_ready("HTTPS proxy", 10.seconds) { proxy_ready? }
          @states["proxy"] = "running"
        rescue ex
          OperationDeadline.without do
            {"proxy" => @proxy_child, "dns" => @dns_child}.each do |name, child|
              begin
                child.stop if !previous[name] && child.running?
              rescue cleanup_error
                STDERR.puts("Latte startup cleanup: #{cleanup_error.class}")
              end
              @states[name] = "failed" unless previous[name]
            end
            begin
              @postgres.stop unless previous["postgres"]
            rescue cleanup_error
              STDERR.puts("Latte database cleanup: #{cleanup_error.class}")
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
          begin
            child.stop if child.running?
            @states[name] = "stopped"
          rescue
            @states[name] = "failed"
            errors = true
          end
        end
        begin
          @postgres.stop
          @states["postgres"] = "stopped"
        rescue
          @states["postgres"] = "failed"
          errors = true
        end
        raise PublicError.new("stop_failed", "A managed service could not stop; check Latte logs") if errors
      end
    end

    def await_idle(timeout : Time::Span = 90.seconds) : Nil
      deadline = Time.instant + timeout
      while @busy
        raise PublicError.new("service_timeout", "Managed services exceeded their deadline") if Time.instant >= deadline
        sleep 20.milliseconds
      end
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
      result = @toolchain.run(:caddy, ["reload", "--config", @proxy.config_file, "--address", "unix/#{@proxy.admin_socket}"], timeout: 5.seconds)
      unless result.success?
        @states["proxy"] = "failed"
        @error = "HTTPS routing could not reload; retry after checking Latte services"
        raise PublicError.new("proxy_reload_failed", "HTTPS routing could not reload; retry after checking Latte services")
      end
      @configuration = File.read(@proxy.config_file)
    end

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
            begin
              if @states["postgres"] == "running" && !@postgres.running?
                @states["postgres"] = "failed"
                crashed = true
              end
              if @states["dns"] == "running" && (!@dns_child.running? || readiness_failed?("dns", dns_ready?))
                @states["dns"] = "failed"
                crashed = true
              end
              if @states["proxy"] == "running"
                if !@proxy_child.running? || readiness_failed?("proxy", proxy_ready?)
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
          end
          if crashed
            if @recovery_attempted
              @error = "A managed service failed after automatic recovery; use Start Services to retry"
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

    private def schedule(state : String, &block : -> Nil) : Nil
      raise PublicError.new("services_busy", "A service operation is already in progress", 409) if @busy
      @busy = true
      @error = nil
      @readiness_misses.keys.each { |key| @readiness_misses[key] = 0 }
      @states.keys.each { |key| @states[key] = state }
      spawn do
        @lock.synchronize do
          begin
            OperationDeadline.run(state == "starting" ? 90.seconds : 60.seconds) { block.call }
          rescue ex
            @error = case ex
                     when PublicError, DeadlineExceeded, Postgres::Error, Toolchain::Unavailable, Toolchain::VersionMismatch
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
    end

    private def require_ready! : Nil
      unless !@busy && @states.values.all? { |state| state == "running" }
        raise PublicError.new("services_not_ready", "Start Latte services and wait for them to be ready", 409)
      end
    end

    private def wait_ready(name : String, timeout : Time::Span, &probe : -> Bool) : Nil
      deadline = Time.instant + OperationDeadline.limit(timeout)
      until probe.call
        OperationDeadline.check!
        raise PublicError.new("service_timeout", "#{name} did not become ready") if Time.instant >= deadline
        sleep 50.milliseconds
      end
    end

    private def child_ready?(child : ManagedChild, &probe : -> Bool) : Bool
      unless child.running?
        raise PublicError.new("service_exited", "#{child.name} exited during startup; check Latte logs")
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
      valid = count > 12 && bytes[0] == 0x43 && bytes[1] == 0x41 && (bytes[2] & 0x80) != 0 && (bytes[3] & 0x0f) == 0
      valid && (!site || ((bytes[6] != 0 || bytes[7] != 0) && bytes[count - 4, 4] == Bytes[127, 0, 0, 1]))
    rescue IO::Error
      false
    ensure
      socket.try(&.close)
    end

    private def proxy_ready? : Bool
      expected = File.read(@proxy.config_file)
      result = ProcessRunner.run(["/usr/bin/curl", "--silent", "--fail", "--max-time", "1", "--noproxy", "*", "--unix-socket", @proxy.admin_socket, "http://localhost/config/"], timeout: 2.seconds, output_limit: expected.bytesize + 4096)
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
      socket = TCPSocket.new("127.0.0.1", @proxy.https_port, timeout.total_seconds, timeout.total_seconds)
      socket.read_timeout = timeout
      socket.write_timeout = timeout
      context = OpenSSL::SSL::Context::Client.new
      context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
      context.ca_certificates = @proxy.root_certificate
      tls = OpenSSL::SSL::Socket::Client.new(socket, context: context, hostname: site.domain, sync_close: true)
      true
    rescue IO::Error | OpenSSL::SSL::Error
      false
    ensure
      tls.try(&.close)
      socket.try(&.close)
    end

    private def admin_available? : Bool
      socket = Socket.unix
      socket.connect(Socket::UNIXAddress.new(@proxy.admin_socket), timeout: OperationDeadline.limit(200.milliseconds))
      true
    rescue IO::Error
      false
    ensure
      socket.try(&.close)
    end
  end
end
