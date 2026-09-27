require "./support/unix_http"
require "uri"
require "http/params"

module Caramel::Checks
  class FrappeProject
    getter root : String
    getter project : String
    getter repo : String
    getter ports : Array(Int32)
    getter env : Hash(String, String?)
    getter daemon : Process?

    def initialize
      @repo = REPO
      toolchain = Checks.toolchain_root("Set CARAMEL_TOOLCHAIN_ROOT to the managed toolchain")
      @psql = File.join(toolchain, "data/installs/conda-postgresql/18.6/bin/psql")
      @root = Checks.private_temp("caramel-frappe-")
      @state = File.join(@root, "state")
      Dir.mkdir(@state, 0o700)
      @projects = File.join(@root, "projects")
      Dir.mkdir(@projects, 0o700)
      @runtime = Checks.runtime_root(@state)
      @socket = File.join(@runtime, "latte.sock")
      @env = {} of String => String?
      ENV.each { |key, value| @env[key] = value unless key.starts_with?("PG") || key.ends_with?("DATABASE_URL") }
      @env["CARAMEL_HOME"] = @state
      @env["CARAMEL_FRAMEWORK_ROOT"] = @repo
      @frappe = File.join(@repo, "bin/frappe")
      @project = File.join(@projects, "bookshelf")
      @daemon = nil
      @app = nil
      @ports = [] of Int32
    end

    def assert!(condition : Bool, message : String = "fixture assertion failed") : Nil
      raise message unless condition
    end

    def command(argv : Array(String), *, chdir : String = @repo, timeout : Time::Span = 180.seconds, echo : Bool = true, environment : Hash(String, String?) = @env, input : String? = nil) : Caramel::Latte::ProcessResult
      result = Checks.run(argv, chdir: chdir, env: environment, input: input, timeout: timeout)
      if echo || !result.success?
        STDOUT.print result.stdout
        STDERR.print result.stderr
      end
      raise "Command failed (#{result.diagnostic}): #{argv.first}" unless result.success?
      result
    end

    def attempt(argv : Array(String), *, chdir : String = @repo, timeout : Time::Span = 180.seconds, environment : Hash(String, String?) = @env) : Caramel::Latte::ProcessResult
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
          states = %w(postgres dns proxy).map { |name| document["services"][name]["state"].as_s }
          return if states.all? { |item| item == state }
          raise "Fixture services failed" if state != "stopped" && states.includes?("failed")
        rescue ex : IO::Error | Socket::Error
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

    def sql(url : String, statement : String) : String
      uri = URI.parse(url)
      query = HTTP::Params.parse(uri.query || "")
      pg_env = environment({"PGPASSWORD" => URI.decode(uri.password || "")})
      command([@psql, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h", query["host"], "-p", query["port"]? || "5432", "-U", URI.decode(uri.user.not_nil!), "-d", uri.path.lchop('/')], environment: pg_env, input: statement, echo: false, timeout: 15.seconds).stdout.strip
    end

    def site(name : String) : JSON::Any
      rpc("GET", "/v1/sites")["sites"].as_a.find { |item| item["name"].as_s == name } || raise "Missing site: #{name}"
    end

    def self.wait_exit(process : Process, timeout : Time::Span, label : String) : Process::Status
      raise "Timed out waiting for #{label}" unless Checks.wait_until(timeout, 50.milliseconds) { process.terminated? }
      process.wait
    end

    def execute(args : Array(String)) : Nil
      puts "Frappé fixture: #{@root}"
      daemon_log = File.open(File.join(@root, "environment.log"), "w")
      app_log = File.open(File.join(@root, "app.log"), "w")
      cleanup_ok = false
      failed = true
      begin
        command([File.join(@repo, "scripts/build-frappe")])
        command([File.join(@repo, "scripts/crystal"), "build", "spec/fixtures/frappe_environment.cr", "-o", File.join(@root, "environment")])
        @ports = [Checks.free_udp_port, Checks.free_tcp_port, Checks.free_tcp_port]
        @daemon = Process.new(File.join(@root, "environment"), [@state] + @ports.map(&.to_s), env: @env, output: daemon_log, error: daemon_log)
        wait_state("running")
        command([@frappe, "new", "bookshelf"], chdir: @projects)
        values = local_values(@project)
        assert!(File.info(File.join(@project, ".env")).permissions.value == 0o600)
        urls = %w(DATABASE_URL MIGRATION_DATABASE_URL SPEC_DATABASE_URL SPEC_MIGRATION_DATABASE_URL).map { |key| values[key] }
        assert!(urls.uniq.size == 4)
        command([@frappe, "make", "resource", "Book", "title:string", "author:string"], chdir: @project)
        command([@frappe, "make", "resource", "Person", "name:string", "age:int32", "total:int64", "active:bool", "rating:float64?", "joined_at:time?", "--plural=people"], chdir: @project)
        routes = command([@frappe, "routes"], chdir: @project, echo: false).stdout
        print routes
        assert!(routes.lines.any? { |line| line.split == %w(GET /books/:id App::Books::Show id:Int64(min=1)) }, routes)
        assert!(routes.lines.any? { |line| line.split == %w(PATCH /people/:id App::People::Update id:Int64(min=1) name:String age:Int32 total:Int64 active:Bool rating:Float64? joined_at:Time?) }, routes)
        command([@frappe, "migrate"], chdir: @project)
        sql(values["MIGRATION_DATABASE_URL"], "CREATE TABLE dev_sentinel (value text NOT NULL); INSERT INTO dev_sentinel VALUES ('keep');")
        command([@frappe, "test"], chdir: @project)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")
        env_path = File.join(@project, ".env")
        original_env = File.read(env_path)
        changed = original_env.sub("SPEC_DATABASE_URL=#{values["SPEC_DATABASE_URL"].to_json}", "SPEC_DATABASE_URL=#{values["DATABASE_URL"].to_json}")
        assert!(changed != original_env)
        File.write(env_path, changed)
        refused = attempt([@frappe, "test"], chdir: @project, timeout: 30.seconds)
        assert!(!refused.success? && refused.stderr.includes?("test refused"), refused.stderr)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")
        File.write(env_path, original_env)
        command([@frappe, "setup"], chdir: @project)
        assert!(local_values(@project)["APP_SECRET"] == values["APP_SECRET"])
        doctor = attempt([@frappe, "doctor"], chdir: @project, timeout: 35.seconds)
        assert!(doctor.stdout.includes?("OK    Managed Crystal compiler"), doctor.stdout)
        assert!(doctor.stdout.includes?("OK    Locked dependencies"), doctor.stdout)
        assert!(File.read(env_path) == original_env)

        clone = File.join(@projects, "bookshelf-clone")
        Dir.mkdir(clone, 0o700)
        Dir.children(@project).each do |entry|
          next if %w(lib .caramel .env).includes?(entry)
          command(["/bin/cp", "-R", File.join(@project, entry), File.join(clone, entry)], echo: false)
        end
        manifest = File.join(clone, "config/environment.yml")
        File.write(manifest, File.read(manifest).sub("name: bookshelf", "name: bookshelf-clone"))
        readme = File.join(clone, "README.md")
        File.write(readme, File.read(readme) + "\nAn application-specific note.\n")
        command([@frappe, "setup"], chdir: clone)
        clone_values = local_values(clone)
        assert!(clone_values["APP_SECRET"] != values["APP_SECRET"])
        assert!(clone_values["DATABASE_URL"] != values["DATABASE_URL"])
        assert!(File.read(readme).ends_with?("An application-specific note.\n"))
        command([@frappe, "test"], chdir: clone)
        assert!(sql(values["DATABASE_URL"], "SELECT value FROM dev_sentinel") == "keep")

        injected = File.join(@root, "package-with-failed-installer")
        Dir.mkdir(injected)
        %w(src templates vendor).each { |folder| command(["/bin/cp", "-R", File.join(@repo, folder), File.join(injected, folder)], echo: false) }
        %w(shard.yml shard.lock LICENSE THIRD_PARTY_NOTICES.md).each { |name| File.copy(File.join(@repo, name), File.join(injected, name)) }
        Dir.mkdir(File.join(injected, "scripts"))
        failed_shards = File.join(injected, "scripts/shards")
        File.write(failed_shards, "#!/bin/sh\nexit 67\n")
        File.chmod(failed_shards, 0o700)
        interrupted = attempt([@frappe, "new", "resumed"], chdir: @projects, timeout: 40.seconds, environment: environment({"CARAMEL_FRAMEWORK_ROOT" => injected}))
        assert!(!interrupted.success? && interrupted.stderr.includes?("frappe setup to resume"), interrupted.stderr)
        resumed = File.join(@projects, "resumed")
        resume_readme = File.join(resumed, "README.md")
        File.write(resume_readme, File.read(resume_readme) + "\nPreserve this edit during setup.\n")
        command([@frappe, "setup"], chdir: resumed)
        assert!(File.read(resume_readme).ends_with?("Preserve this edit during setup.\n"))
        Dev.new(self, clone).check if args.includes?("--dev")
        Benchmark.new(self, edit_only: args.includes?("--edit-benchmark")).check if args.includes?("--benchmark") || args.includes?("--edit-benchmark")

        selected = site("bookshelf")
        app_dir = File.join(@runtime, "sites", selected["id"].as_s)
        FileUtils.mkdir_p(app_dir)
        File.chmod(app_dir, 0o700)
        app_socket = File.join(app_dir, "app.sock")
        app_env = environment(values.merge({"CARAMEL_ENV" => "development", "CARAMEL_SOCKET" => app_socket}))
        @app = Process.new(File.join(@project, ".caramel/application"), ["serve"], chdir: @project, env: app_env, output: app_log, error: app_log)
        assert!(Checks.wait_until(10.seconds, 50.milliseconds) { File.exists?(app_socket) || @app.not_nil!.terminated? } && File.exists?(app_socket), "Generated application failed to start")
        rpc("POST", "/v1/sites/#{selected["id"].as_s}/upstream", JSON.parse({socket: app_socket}.to_json))
        certificate = File.join(@state, "services/caddy/storage/pki/authorities/caramel/root.crt")
        page = command(["/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "5", "--noproxy", "*", "--cacert", certificate, "--resolve", "bookshelf.caramel:#{@ports[2]}:127.0.0.1", "-H", "Host: bookshelf.caramel", "https://bookshelf.caramel:#{@ports[2]}/"], echo: false)
        assert!(page.stdout.includes?("A little less setup.") && page.stdout.includes?("/assets/htmx-4.0.0.min.js"))
        puts "PASS: real frappe new/setup/migrate/routes/test, clone secrets, failed-dependency recovery, source preservation, test refusal for development URL, retained development data, and generated native app over CA-verified named HTTPS"
        failed = false
      ensure
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
        ensure
          daemon_log.close
          app_log.close
        end
      end
    end
  end
end
require "./frappe_project/dev"
require "./frappe_project/benchmark"


begin
  Caramel::Checks::FrappeProject.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
