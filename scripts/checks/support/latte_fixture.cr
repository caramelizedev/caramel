require "./unix_http"

module Caramel::Checks
  # A private Latte daemon on free DNS/HTTP/HTTPS ports with Frappé projects
  # under one disposable temp root. `finish` removes the root only after a
  # passing run whose services stopped cleanly.
  class LatteFixture
    getter root : String
    getter repo : String
    getter projects : String
    getter ports : Array(Int32)
    getter env : Hash(String, String?)
    getter daemon : Process?
    getter app : Process?

    def initialize(prefix : String)
      @repo = REPO
      @root = Checks.private_temp(prefix)
      @state = File.join(@root, "state")
      Dir.mkdir(@state, 0o700)
      @projects = File.join(@root, "projects")
      Dir.mkdir(@projects, 0o700)
      @runtime = Checks.runtime_root(@state)
      @socket = File.join(@runtime, "latte.sock")
      @env = {} of String => String?
      ENV.each do |key, value|
        next if key.starts_with?("PG") || key.ends_with?("DATABASE_URL")
        @env[key] = value
      end
      @env["CARAMEL_HOME"] = @state
      @env["CARAMEL_FRAMEWORK_ROOT"] = @repo
      @frappe = File.join(@repo, "bin/frappe")
      @daemon = nil
      @app = nil.as(Process?)
      @ports = [] of Int32
      @daemon_log = File.open(File.join(@root, "environment.log"), "w")
      @app_log = File.open(File.join(@root, "app.log"), "w")
    end

    def https_port : Int32
      @ports[2]
    end

    def certificate : String
      File.join(@state, "services/caddy/storage/pki/authorities/caramel/root.crt")
    end

    def assert!(condition : Bool, message : String = "fixture assertion failed") : Nil
      raise message unless condition
    end

    def command(argv : Array(String), *,
                chdir : String = @repo,
                timeout : Time::Span = 180.seconds,
                echo : Bool = true,
                environment : Hash(String, String?) = @env,
                input : String? = nil) : Caramel::Latte::ProcessResult
      result = Checks.run(argv, chdir: chdir, env: environment, input: input, timeout: timeout)
      if echo || !result.success?
        STDOUT.print result.stdout
        STDERR.print result.stderr
      end
      raise "Command failed (#{result.diagnostic}): #{argv.first}" unless result.success?
      result
    end

    def attempt(argv : Array(String), *,
                chdir : String = @repo,
                timeout : Time::Span = 180.seconds,
                environment : Hash(String, String?) = @env) : Caramel::Latte::ProcessResult
      Checks.run(argv, chdir: chdir, env: environment, timeout: timeout)
    end

    def environment(extra : Hash(String, String)) : Hash(String, String?)
      merged = @env.dup
      extra.each { |key, value| merged[key] = value }
      merged
    end

    def rpc(method : String, path : String, body : JSON::Any? = nil) : JSON::Any
      UnixHTTP.json!(@socket, method, path, body)
    end

    def wait_state(state : String, timeout : Time::Span = 100.seconds) : Nil
      deadline = Time.instant + timeout
      while Time.instant < deadline
        raise "Fixture daemon exited" if @daemon.try(&.terminated?)
        begin
          document = rpc("GET", "/v1/status")
          states = %w[postgres dns proxy].map { |name| document["services"][name]["state"].as_s }
          return if states.all? { |item| item == state }
          raise "Fixture services failed" if state != "stopped" && states.includes?("failed")
        rescue IO::Error | Socket::Error
          # The socket may not exist yet during startup.
        end
        sleep 100.milliseconds
      end
      raise "Fixture services did not reach #{state}"
    end

    def local_values(directory : String) : Hash(String, String)
      values = {} of String => String
      File.each_line(File.join(directory, ".env")) do |line|
        next if line.empty? || line.starts_with?('#')
        key, value = line.split('=', 2)
        values[key] = JSON.parse(value).as_s
      end
      values
    end

    def site(name : String) : JSON::Any
      sites = rpc("GET", "/v2/sites")["sites"].as_a
      sites.find { |item| item["name"].as_s == name } || raise "Missing site: #{name}"
    end

    def self.wait_exit(process : Process, timeout : Time::Span, label : String) : Process::Status
      exited = Checks.wait_until(timeout, 50.milliseconds) { process.terminated? }
      raise "Timed out waiting for #{label}" unless exited
      process.wait
    end

    # Builds Frappé and the environment daemon, unless scripts/check all's
    # build step already has, then starts PostgreSQL, DNS and Caddy on free
    # ports.
    def start : Nil
      environment = Checks::PREBUILT_ENVIRONMENT
      unless Checks.prebuilt?
        command([File.join(@repo, "scripts/build-frappe")])
        environment = File.join(@root, "environment")
        source = "spec/fixtures/frappe_environment.cr"
        command([File.join(@repo, "scripts/crystal"), "build", source, "-o", environment])
      end
      @ports = [Checks.free_udp_port, Checks.free_tcp_port, Checks.free_tcp_port,
                Checks.free_tcp_port]
      home = File.join(@root, "home")
      Dir.mkdir(home, 0o700)
      # Trust-store discovery follows HOME (NSS) and JAVA_HOME. Keep both
      # inside the fixture as a second barrier behind the untrusted CAs.
      daemon_env = @env.merge({"HOME" => home, "JAVA_HOME" => nil} of String => String?)
      arguments = [@state] + @ports.map(&.to_s)
      @daemon = Process.new(environment, arguments,
        env: daemon_env, output: @daemon_log, error: @daemon_log)
      wait_state("running")
      trust_guard!
    end

    def trust_guard! : Nil
      if violation = trust_violation
        raise violation
      end
    end

    # Caddy may keep only CAs that its current configuration declares
    # untrusted and must never attempt a trust-store installation. On any
    # violation every fixture CA private key is deleted, so no root that an
    # external store may now trust can sign anything.
    def trust_violation : String?
      caddy = File.join(@state, "services/caddy")
      authorities = File.join(caddy, "storage/pki/authorities")
      present = Dir.exists?(authorities) ? Dir.children(authorities) : [] of String
      untrusted = untrusted_authorities(File.join(caddy, "caddy.json"))
      installing = installation_logged?
      unexpected = present - untrusted
      return if unexpected.empty? && !installing
      present.each do |name|
        Dir.glob(File.join(authorities, name, "*.key")).each { |key| File.delete(key) }
      end
      "Caddy attempted a trust-store installation (#{installing}) " \
      "or kept CAs not declared untrusted (#{unexpected}); " \
      "deleted every fixture CA private key under #{authorities}"
    end

    # The CAs that Caddy's configuration at *config* declares untrusted.
    private def untrusted_authorities(config : String) : Array(String)
      return [] of String unless File.exists?(config)

      document = JSON.parse(File.read(config))
      declared = document.dig?("apps", "pki", "certificate_authorities").try(&.as_h?)
      return [] of String unless declared

      declared.select { |_, authority| authority["install_trust"]? == false }.keys
    end

    # Whether a proxy log records Caddy installing a root certificate.
    private def installation_logged? : Bool
      Dir.glob(File.join(@state, "logs/proxy*.log")).any? do |log|
        File.read(log).includes?("installing root certificate")
      end
    end

    # Runs a project's compiled application on its site's private socket and
    # routes the site's Caddy host to it.
    def serve(project : String, name : String, values : Hash(String, String)) : Nil
      selected = site(name)
      app_dir = File.join(@runtime, "sites", selected["id"].as_s)
      FileUtils.mkdir_p(app_dir)
      File.chmod(app_dir, 0o700)
      app_socket = File.join(app_dir, "app.sock")
      settings = {"CARAMEL_ENV" => "development", "CARAMEL_SOCKET" => app_socket}
      app_env = environment(values.merge(settings))
      binary = File.join(project, ".caramel/application")
      app = Process.new(binary, ["serve"],
        chdir: project, env: app_env, output: @app_log, error: @app_log)
      @app = app
      started = Checks.wait_until(10.seconds, 50.milliseconds) do
        File.exists?(app_socket) || app.terminated?
      end
      listening = started && File.exists?(app_socket)
      assert!(listening, "Generated application failed to start")
      upstream = JSON.parse({socket: app_socket}.to_json)
      rpc("POST", "/v1/sites/#{selected["id"].as_s}/upstream", upstream)
      trust_guard!
    end

    def finish(failed : Bool) : Nil
      cleanup_ok = false
      begin
        if app = @app
          Checks.stop(app, 15.seconds) unless app.terminated?
        end
        if daemon = @daemon
          unless daemon.terminated?
            begin
              rpc("POST", "/v1/services/stop", JSON.parse("{}"))
              wait_state("stopped", 70.seconds)
              cleanup_ok = true
            ensure
              Checks.stop(daemon, 90.seconds)
            end
          end
        else
          cleanup_ok = true
        end
      ensure
        violation = trust_violation
      end
      failed ||= !violation.nil?
      if cleanup_ok
        if failed
          STDERR.puts "Services stopped; preserved failed fixture for inspection: #{@root}"
        else
          FileUtils.rm_rf(@runtime)
          FileUtils.rm_rf(@root)
        end
      else
        STDERR.puts "Cleanup needs inspection; preserved #{@root}"
      end
      raise violation if violation
    ensure
      @daemon_log.close
      @app_log.close
    end
  end
end
