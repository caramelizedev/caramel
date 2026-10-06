module Caramel::Checks
  class FrappeProject::Dev
    FAILED  = "development fixture assertion failed"
    WELCOME = "A little less setup."
    HANDLE  = "def handle(contract : Contract)\n"

    def initialize(@fixture : FrappeProject, @clone : String)
      @processes = [] of Process
      @logs = [] of File
      @executable = File.join(@fixture.root, "dev-fixture")
    end

    private def assert!(condition : Bool, message : String = FAILED) : Nil
      @fixture.assert!(condition, message)
    end

    private def request(name : String,
                        path : String = "/",
                        headers : Array(String) = [] of String) : {Int32, String}
      jar = File.join(@fixture.root, "#{name}-cookies")
      port = @fixture.ports[2]
      command = ["/usr/bin/curl", "--silent", "--show-error",
                 "--max-time", "5", "--noproxy", "*",
                 "--cacert", @fixture.certificate,
                 "--resolve", "#{name}.caramel:#{port}:127.0.0.1",
                 "-H", "Host: #{name}.caramel",
                 "--cookie", jar, "--cookie-jar", jar,
                 "--write-out", "\n%{http_code}"]
      headers.each { |header| command.concat(["-H", header]) }
      url = "https://#{name}.caramel:#{port}#{path}"
      result = @fixture.attempt(command + [url], timeout: 8.seconds)
      index = result.stdout.rindex('\n')
      return {0, result.stdout} unless index
      {result.stdout[(index + 1)..].strip.to_i? || 0, result.stdout[0...index]}
    end

    private def wait_for(name : String,
                         timeout : Time::Span = 100.seconds,
                         headers : Array(String) = [] of String,
                         & : Int32, String -> Bool) : String
      deadline = Time.instant + timeout
      status = 0
      body = ""
      while Time.instant < deadline
        status, body = request(name, headers: headers)
        return body if yield status, body
        running = @processes.all? { |process| !process.terminated? }
        assert!(running, "dev session exited; inspect fixture logs")
        sleep 150.milliseconds
      end
      raise "Timed out waiting for #{name}: #{status}\n#{body[0, Math.min(3000, body.size)]}"
    end

    # Waits for *name* to serve its welcome page, and returns the page.
    private def wait_ready(name : String) : String
      wait_for(name) { |code, content| code == 200 && content.includes?(WELCOME) }
    end

    # Waits for *name* to answer 503 with a page that includes *text*.
    private def wait_unavailable(name : String, text : String) : String
      wait_for(name) { |code, content| code == 503 && content.includes?(text) }
    end

    # The start of a development exception page, for a failed assertion.
    private def excerpt(body : String) : String
      body[0, Math.min(16000, body.size)]
    end

    # Asserts that the summary above the collapsed stack frames locates the
    # error in the action.
    private def assert_located!(body : String) : Nil
      summary = body.split("<details>")[0]
      assert!(summary.includes?("app/actions/home/show.cr:"), excerpt(body))
    end

    private def start(directory : String, name : String, runtime_url : String? = nil) : Process
      log = File.open(File.join(@fixture.root, "#{name}-dev.log"), "w")
      @logs << log
      environment = @fixture.env
      if runtime_url
        environment = environment.merge({"CARAMEL_DEV_RUNTIME_URL" => runtime_url})
      end
      process = Process.new(@executable, [directory],
        chdir: directory, env: environment, output: log, error: log)
      @processes << process
      process
    end

    private def finish(process : Process, timeout : Time::Span = 20.seconds) : Nil
      process.terminate unless process.terminated?
      status = FrappeProject.wait_exit(process, timeout, "dev session")
      assert!(status.success?, "dev session did not exit cleanly")
      @processes.delete(process)
    end

    private def site(name : String) : JSON::Any
      @fixture.site(name)
    end

    def check : Nil
      p = @fixture
      crystal = File.join(p.repo, "scripts/crystal")
      frappe = File.join(p.repo, "bin/frappe")
      p.command([crystal, "build", "spec/fixtures/frappe_dev.cr", "-o", @executable])
      project = p.project
      begin
        first = start(project, "bookshelf")
        body = wait_ready("bookshelf")
        assert!(body.includes?("/__caramel/dev/client.js"))
        status, state = request("bookshelf", "/__caramel/dev/status", ["X-Caramel-Dev: 1"])
        assert!(status == 200 && JSON.parse(state)["state"].as_s == "ready")
        current = site("bookshelf")
        assert!(current["state"].as_s == "running" && current["owner"].as_s == "terminal")
        initial_generation = JSON.parse(state)["generation"].as_i64
        duplicate = p.attempt([@executable, project], chdir: project, timeout: 20.seconds)
        assert!(!duplicate.success? && duplicate.stderr.includes?("already running"))

        # Setup migrated the clone; a resource added since gives it a pending
        # migration, which this branch, taken before migrating, keeps.
        p.command([frappe, "make", "resource", "Memo", "body:string"],
          chdir: @clone, echo: false)
        create_branch = [frappe, "db", "branch", "create", "unmigrated"]
        branch_url = p.command(create_branch, chdir: @clone, echo: false).stdout.strip
        url_printed = branch_url.starts_with?("postgresql://") &&
                      branch_url.includes?("_unmigrated?")
        assert!(url_printed, "branch create did not print a runtime URL")
        clone_session = start(@clone, "bookshelf-clone")
        wait_unavailable("bookshelf-clone", "Pending migrations")
        # Let the session retry a few times before the migration is applied.
        sleep 3.seconds
        p.command([frappe, "migrate"], chdir: @clone)
        # frappe migrate reused the build the session made of the same sources.
        command_build = File.join(@clone, ".caramel/application")
        session_builds = Dir.glob(File.join(@clone, ".caramel/dev/application-*"))
        assert!(session_builds.any? { |build| File.same?(build, command_build) },
          "frappe migrate rebuilt the sources frappe dev had built")
        diagnosis = p.command([frappe, "db", "diagnose"], chdir: @clone, echo: false).stdout
        assert!(diagnosis.includes?("== table_sizes =="), diagnosis)
        wait_ready("bookshelf-clone")
        clone_log = File.read(File.join(p.root, "bookshelf-clone-dev.log"))
        once = clone_log.scan("Pending migrations").size == 1
        assert!(once && clone_log.includes?("Application ready"),
          "frappe dev did not report the pending migration exactly once:\n#{clone_log}")

        controller = File.join(project, "app/actions/home/show.cr")
        original = File.read(controller)
        probe = File.join(project, "app/compile_probe.cr")
        marker = File.join(project, ".caramel/cancel-probe.pid")
        # The blank line before the terminator ends the probe with a newline.
        File.write(probe, <<-CR)
          Signal::TERM.ignore
          File.write(ARGV[0], Process.pid.to_s)
          sleep 30.seconds
          puts "nil"

          CR
        File.write(controller, "{{ run(#{probe.to_json}, #{marker.to_json}) }}\n" + original)
        started = Checks.wait_until(30.seconds, 50.milliseconds) do
          File.exists?(marker) || first.terminated?
        end
        probing = started && File.exists?(marker)
        assert!(probing, "compiler cancellation probe did not start")
        macro_pid = File.read(marker).to_i64
        assert!(request("bookshelf")[0] == 503, "stale app served while compiling")
        assert!(request("bookshelf-clone")[0] == 200)
        File.write(controller, original)
        File.delete(probe)
        wait_ready("bookshelf")
        macro_gone = Checks.wait_until(5.seconds, 50.milliseconds) do
          Checks.gone?(macro_pid)
        end
        assert!(macro_gone, "superseded compiler left its macro process alive")
        assert!(Dir.glob(File.join(project, ".caramel/dev/building-*")).empty?)
        puts "PASS: superseded real compilation cancels a TERM-resistant macro " \
             "and never serves stale code"

        File.write(controller, original + "\ndef deliberately_broken(\n")
        wait_unavailable("bookshelf", "app/actions/home/show.cr")
        current = site("bookshelf")
        assert!(current["state"].as_s == "build-error" && current["owner"].as_s == "terminal")
        listed = p.command([frappe, "sites"], echo: false).stdout
        failing = listed.lines.any? do |line|
          line.includes?("bookshelf ") && line.includes?("build-error (terminal)")
        end
        assert!(failing, listed)
        compiler_logs = [frappe, "logs", "compiler"]
        compiler_log = p.command(compiler_logs, chdir: project, echo: false).stdout
        steps = ["app/actions/home/show.cr", "check bookshelf", "build bookshelf"]
        assert!(steps.all? { |step| compiler_log.includes?(step) }, compiler_log)
        application_log = p.command([frappe, "logs"], chdir: project, echo: false).stdout
        assert!(application_log.includes?("start bookshelf"), application_log)
        assert!(body.includes?("data-request="), "the served page does not name its request")
        feed = ["X-Caramel-Dev: 1"]
        found_traces = [] of JSON::Any
        listed_trace = Checks.wait_until(10.seconds, 100.milliseconds) do
          listed = JSON.parse(request("bookshelf", "/__caramel/dev/traces.json", feed)[1])
          match = listed["traces"].as_a.find { |item| item["name"].as_s == "GET /" }
          found_traces << match if match
          !match.nil?
        rescue JSON::ParseException | KeyError | TypeCastError
          false
        end
        assert!(listed_trace, "traces.json does not list GET /")
        page_trace = found_traces.last
        page_request = page_trace["request_id"].as_s
        in_access_log = Checks.wait_until(15.seconds, 500.milliseconds) do
          access = p.attempt([frappe, "logs", "access"], chdir: project, timeout: 30.seconds)
          access.stdout.includes?(page_request)
        end
        assert!(in_access_log, "frappe logs access does not show the page's request id")
        page_trace_id = page_trace["trace_id"].as_s
        last_rpc = "no answer yet"
        collected = Checks.wait_until(15.seconds, 500.milliseconds) do
          spans = p.rpc("GET", "/v2/traces/#{page_trace_id}")["spans"].as_a
          spans.any? { |span| span["service"].as_s == "bookshelf" }
        rescue ex
          last_rpc = "#{ex.class}: #{ex.message}"
          false
        end
        collector_failure = "Latte's collector holds no span of service bookshelf for the page " \
                            "(last rpc: #{last_rpc})"
        assert!(collected, collector_failure)
        runtime_url = p.local_values(project)["DATABASE_URL"]
        recorded = Checks.wait_until(30.seconds, 1.second) do
          (p.sql(runtime_url, "SELECT count(*) FROM caramel_metrics").strip.to_i? || 0) > 0
        end
        assert!(recorded, "the recorder wrote no caramel_metrics row")
        # Under scripts/check all the build step has already built Latte.app.
        p.command([File.join(p.repo, "scripts/build-latte-menu")]) unless Checks.prebuilt?
        latte = File.join(p.repo, "bin/Latte.app/Contents/MacOS/Latte")
        menu = p.command([latte, "--check"], echo: false).stdout
        assert!(menu.includes?("[Build error] · Terminal session"), menu)
        assert!(menu.includes?("/logs/sites/#{site("bookshelf")["id"].as_s}"), menu)
        assert!(menu.includes?("/__caramel/dev/inspector"), menu)
        puts "PASS: persistent per-site compiler and application logs " \
             "through frappe logs and the menu"
        assert!(request("bookshelf-clone")[0] == 200)
        File.write(controller, original)
        wait_ready("bookshelf")
        log_path = File.join(p.root, "bookshelf-dev.log")
        builds = File.read(log_path).scan("Building bookshelf").size
        failures = File.read(log_path).scan(/Type check failed in \d+ ms/).size
        passes = File.read(log_path).scan(/Type check passed in \d+ ms/).size
        type_error = <<-CR
          def handle(contract : Contract)
                tier_one_probe = 1 + "two"

          CR
        File.write(controller, original.sub(HANDLE, type_error))
        body = wait_unavailable("bookshelf", "app/actions/home/show.cr")
        tail = body[Math.max(0, body.size - 3000)..]
        operator = body.includes?("to &#39;Int32#+&#39;")
        assert!(operator && body.includes?("not String"), tail)
        assert!(body.includes?("zed://file/"), "the type error page has no editor link")
        reported = Checks.wait_until(5.seconds, 50.milliseconds) do
          File.read(log_path).scan(/Type check failed in \d+ ms/).size == failures + 1
        end
        assert!(reported, "type error did not print Type check failed")
        built = File.read(log_path).scan("Building bookshelf").size
        assert!(built == builds, "type error reached code generation")
        assert!(site("bookshelf")["state"].as_s == "build-error")
        File.write(controller, original + "\n# Tier-1 recovery proof\n")
        wait_ready("bookshelf")
        passed = File.read(log_path).scan(/Type check passed in \d+ ms/).size
        assert!(passed > passes, "fixed source did not print Type check passed")
        built = File.read(log_path).scan("Building bookshelf").size
        assert!(built == builds + 1, "fixed source did not build once")
        puts "PASS: Tier-1 type check shows a planted type error " \
             "without code generation, then the fix type-checks and builds"
        diagnostic_headers = ["X-Diagnostic-Proof: 1"]
        # A backslash at a line's end joins it to the next line.
        runtime_error = <<-CR
          def handle(contract : Contract)
                raise "runtime-diagnostic-proof <escaped>" \
                  if request.headers["X-Diagnostic-Proof"]? == "1"

          CR
        File.write(controller, original.sub(HANDLE, runtime_error))
        assert!(File.read(controller) != original)
        body = wait_for("bookshelf", headers: diagnostic_headers) do |code, content|
          code == 500 && content.includes?("CARAMEL DEVELOPMENT EXCEPTION")
        end
        escaped = body.includes?("runtime-diagnostic-proof &lt;escaped&gt;")
        assert!(escaped && body.includes?("app/actions/home/show.cr:"), excerpt(body))
        assert_located!(body)
        assert!(body.includes?("Internal stack frames"))
        errors = p.attempt([frappe, "errors", "--agent"], chdir: project, timeout: 30.seconds)
        reported = Checks.wait_until(10.seconds, 200.milliseconds) do
          errors = p.attempt([frappe, "errors", "--agent"], chdir: project, timeout: 30.seconds)
          errors.stdout.includes?("ERR RUNTIME:500 at app/")
        end
        assert!(reported && !errors.success?, "frappe errors did not report the planted error")
        last = p.command([frappe, "trace", "last-error", "--md"], chdir: project, echo: false)
        assert!(last.stdout.includes?("## Backtrace"), last.stdout)
        counted = Checks.wait_until(10.seconds, 500.milliseconds) do
          p.command([latte, "--check"], echo: false).stdout.matches?(/errors: [1-9]\d*\b/)
        end
        assert!(counted, "Latte.app --check did not report the planted runtime error")
        menu = p.command([latte, "--check"], echo: false).stdout
        assert!(menu.includes?("last error: "), menu)
        assert!(site("bookshelf")["errors"].as_i > 0, "the control API lists no errors")
        assert!(site("bookshelf")["state"].as_s == "running")
        wait_ready("bookshelf")
        status, state = request("bookshelf", "/__caramel/dev/status", ["X-Caramel-Dev: 1"])
        assert!(status == 200 && JSON.parse(state)["generation"].as_i64 > initial_generation)

        source = File.join(project, "app/assets/stylesheets/app.css")
        before = File.read(log_path).scan("Build ready").size
        checks = File.read(log_path).scan("Type check").size
        File.write(source, File.read(source) + "\n/* dev-asset-refresh-proof */\n")
        published = Checks.wait_until(8.seconds, 100.milliseconds) do
          request("bookshelf", "/assets/app.css")[1].includes?("dev-asset-refresh-proof")
        end
        assert!(published, "asset changes did not publish")
        sleep 500.milliseconds
        uncompiled = File.read(log_path).scan("Build ready").size == before &&
                     File.read(log_path).scan("Type check").size == checks
        assert!(uncompiled, "CSS triggered a Crystal compile")
        destination = File.join(project, "public/assets/app.css")
        File.write(destination, "A public edit that must be preserved")
        wait_unavailable("bookshelf", "Asset output conflict")
        assert!(File.read(destination) == "A public edit that must be preserved")
        File.write(destination, File.read(source))
        wait_ready("bookshelf")

        finish(first)
        current = site("bookshelf")
        assert!(current["upstream"].raw.nil?)
        assert!(current["state"].as_s == "stopped" && current["owner"].raw.nil?)
        assert!(request("bookshelf")[0] == 503)
        assert!(request("bookshelf-clone")[0] == 200)
        services = p.rpc("GET", "/v1/status")["services"].as_h.values
        assert!(services.all? { |item| item["state"].as_s == "running" })

        restarted = start(project, "bookshelf")
        wait_ready("bookshelf")
        cached = Checks.wait_until(5.seconds, 50.milliseconds) do
          File.read(log_path).includes?("Build ready (cached)")
        end
        assert!(cached)
        status, body = request("bookshelf", headers: diagnostic_headers)
        assert!(status == 500, excerpt(body))
        assert_located!(body)
        listing = p.command(["/bin/ps", "-ax", "-o", "pid=,args="], echo: false).stdout
        application = File.join(project, ".caramel/dev/application-")
        native_pids = listing.lines.compact_map do |line|
          parts = line.strip.split(/\s+/, 2)
          parts[0].to_i64? if parts.size == 2 && parts[1].starts_with?(application)
        end
        assert!(native_pids.size == 1, "expected one owned native app")
        restarted.terminate(graceful: false)
        FrappeProject.wait_exit(restarted, 5.seconds, "killed terminal owner")
        @processes.delete(restarted)
        natives_gone = Checks.wait_until(8.seconds, 50.milliseconds) do
          native_pids.all? do |pid|
            ps = ["/bin/ps", "-p", pid.to_s, "-o", "stat=,args="]
            info = p.attempt(ps, timeout: 5.seconds).stdout.strip
            info.empty? || info.starts_with?('Z') || !info.includes?(application)
          end
        end
        assert!(natives_gone, "native app survived terminal owner death")
        restarted = start(project, "bookshelf")
        wait_ready("bookshelf")
        assert!(request("bookshelf-clone")[0] == 200)
        finish(restarted)
        build_directory = File.join(project, ".caramel/dev")
        debug_files = Dir.glob(File.join(build_directory, "application-*.dwarf"))
        assert!(debug_files.size == 1, debug_files.to_s)
        assert!(Dir.glob(File.join(build_directory, "building-*")).empty?)
        File.delete(debug_files[0])
        start(project, "bookshelf")
        body = wait_for("bookshelf", headers: diagnostic_headers) do |code, content|
          code == 500 && content.includes?("CARAMEL DEVELOPMENT EXCEPTION")
        end
        assert_located!(body)
        assert!(File.file?(debug_files[0]))
        assert!(!File.read(log_path).includes?("Build ready (cached)"))
        finish(clone_session)
        branched = start(@clone, "bookshelf-clone", runtime_url: branch_url)
        wait_unavailable("bookshelf-clone", "Pending migrations")
        finish(branched)
        delete_branch = [frappe, "db", "branch", "delete", "unmigrated"]
        p.command(delete_branch, chdir: @clone, echo: false)
        puts "PASS: a runtime URL override runs the migrated clone " \
             "against its unmigrated Latte branch, whose pending migration shows"
        puts "PASS: runtime application locations, cached traces, " \
             "missing debug-file recovery, and live CLI/native menu state"
        puts "PASS: cached restart, abrupt terminal death cleanup, " \
             "stale socket recovery, and asset-conflict recovery"
        puts "PASS: watched native builds, same-origin diagnostics/recovery, " \
             "pending-migration recovery, authenticated refresh, " \
             "CSS without compilation, duplicate session refusal, " \
             "and independent project shutdown"
      ensure
        @processes.each { |process| Checks.stop(process, 20.seconds) unless process.terminated? }
        @logs.each(&.close)
      end
    end
  end
end
