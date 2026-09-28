module Caramel::Checks
  class FrappeProject::Dev
    def initialize(@fixture : FrappeProject, @clone : String)
      @processes = [] of Process
      @logs = [] of File
      @executable = File.join(@fixture.root, "dev-fixture")
    end

    private def assert!(condition : Bool, message : String = "development fixture assertion failed") : Nil
      @fixture.assert!(condition, message)
    end

    private def request(name : String, path : String = "/", headers : Array(String) = [] of String) : {Int32, String}
      jar = File.join(@fixture.root, "#{name}-cookies")
      certificate = File.join(@fixture.root, "state/services/caddy/storage/pki/authorities/caramel/root.crt")
      command = ["/usr/bin/curl", "--silent", "--show-error", "--max-time", "5", "--noproxy", "*", "--cacert", certificate, "--resolve", "#{name}.caramel:#{@fixture.ports[2]}:127.0.0.1", "-H", "Host: #{name}.caramel", "--cookie", jar, "--cookie-jar", jar, "--write-out", "\n%{http_code}"]
      headers.each { |header| command.concat(["-H", header]) }
      result = @fixture.attempt(command + ["https://#{name}.caramel:#{@fixture.ports[2]}#{path}"], timeout: 8.seconds)
      index = result.stdout.rindex('\n')
      return {0, result.stdout} unless index
      {result.stdout[(index + 1)..].strip.to_i? || 0, result.stdout[0...index]}
    end

    private def wait_for(name : String, timeout : Time::Span = 100.seconds, headers : Array(String) = [] of String, & : Int32, String -> Bool) : String
      deadline = Time.instant + timeout
      status = 0
      body = ""
      while Time.instant < deadline
        status, body = request(name, headers: headers)
        return body if yield status, body
        assert!(@processes.all? { |process| !process.terminated? }, "dev session exited; inspect fixture logs")
        sleep 150.milliseconds
      end
      raise "Timed out waiting for #{name}: #{status}\n#{body[0, Math.min(3000, body.size)]}"
    end

    private def start(directory : String, name : String, runtime_url : String? = nil) : Process
      log = File.open(File.join(@fixture.root, "#{name}-dev.log"), "w")
      @logs << log
      environment = runtime_url ? @fixture.env.merge({"CARAMEL_DEV_RUNTIME_URL" => runtime_url}) : @fixture.env
      process = Process.new(@executable, [directory], chdir: directory, env: environment, output: log, error: log)
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
      p.command([File.join(p.repo, "scripts/crystal"), "build", "spec/fixtures/frappe_dev.cr", "-o", @executable])
      project = p.project
      begin
        first = start(project, "bookshelf")
        body = wait_for("bookshelf") { |status, content| status == 200 && content.includes?("A little less setup.") }
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
        p.command([File.join(p.repo, "bin/frappe"), "make", "resource", "Note", "body:string"], chdir: @clone, echo: false)
        branch_url = p.command([File.join(p.repo, "bin/frappe"), "db", "branch", "create", "unmigrated"], chdir: @clone, echo: false).stdout.strip
        assert!(branch_url.starts_with?("postgresql://") && branch_url.includes?("_unmigrated?"), "branch create did not print a runtime URL")
        clone_session = start(@clone, "bookshelf-clone")
        wait_for("bookshelf-clone") { |code, content| code == 503 && content.includes?("Pending migrations") }
        # Let the session retry a few times before the migration is applied.
        sleep 3.seconds
        p.command([File.join(p.repo, "bin/frappe"), "migrate"], chdir: @clone)
        wait_for("bookshelf-clone") { |code, content| code == 200 && content.includes?("A little less setup.") }
        clone_log = File.read(File.join(p.root, "bookshelf-clone-dev.log"))
        assert!(clone_log.scan("Pending migrations").size == 1 && clone_log.includes?("Application ready"), "frappe dev did not report the pending migration exactly once:\n#{clone_log}")

        controller = File.join(project, "app/actions/home/show.cr")
        original = File.read(controller)
        probe = File.join(project, "app/compile_probe.cr")
        marker = File.join(project, ".caramel/cancel-probe.pid")
        File.write(probe, "Signal::TERM.ignore\nFile.write(ARGV[0], Process.pid.to_s)\nsleep 30.seconds\nputs \"nil\"\n")
        File.write(controller, "{{ run(#{probe.to_json}, #{marker.to_json}) }}\n" + original)
        assert!(Checks.wait_until(30.seconds, 50.milliseconds) { File.exists?(marker) || first.terminated? } && File.exists?(marker), "compiler cancellation probe did not start")
        macro_pid = File.read(marker).to_i64
        assert!(request("bookshelf")[0] == 503, "stale app served while compiling")
        assert!(request("bookshelf-clone")[0] == 200)
        File.write(controller, original)
        File.delete(probe)
        wait_for("bookshelf") { |code, content| code == 200 && content.includes?("A little less setup.") }
        assert!(Checks.wait_until(5.seconds, 50.milliseconds) { Checks.gone?(macro_pid) }, "superseded compiler left its macro process alive")
        assert!(Dir.glob(File.join(project, ".caramel/dev/building-*")).empty?)
        puts "PASS: superseded real compilation cancels a TERM-resistant macro and never serves stale code"

        File.write(controller, original + "\ndef deliberately_broken(\n")
        wait_for("bookshelf") { |code, content| code == 503 && content.includes?("app/actions/home/show.cr") }
        current = site("bookshelf")
        assert!(current["state"].as_s == "build-error" && current["owner"].as_s == "terminal")
        listed = p.command([File.join(p.repo, "bin/frappe"), "sites"], echo: false).stdout
        assert!(listed.lines.any? { |line| line.includes?("bookshelf ") && line.includes?("build-error (terminal)") }, listed)
        compiler_log = p.command([File.join(p.repo, "bin/frappe"), "logs", "compiler"], chdir: project, echo: false).stdout
        assert!(compiler_log.includes?("app/actions/home/show.cr") && compiler_log.includes?("check bookshelf") && compiler_log.includes?("build bookshelf"), compiler_log)
        application_log = p.command([File.join(p.repo, "bin/frappe"), "logs"], chdir: project, echo: false).stdout
        assert!(application_log.includes?("start bookshelf"), application_log)
        p.command([File.join(p.repo, "scripts/build-latte-menu")])
        menu = p.command([File.join(p.repo, "bin/Latte.app/Contents/MacOS/Latte"), "--check"], echo: false).stdout
        assert!(menu.includes?("[Build error] · Terminal session"), menu)
        assert!(menu.includes?("/logs/sites/#{site("bookshelf")["id"].as_s}"), menu)
        puts "PASS: persistent per-site compiler and application logs through frappe logs and the menu"
        assert!(request("bookshelf-clone")[0] == 200)
        File.write(controller, original)
        wait_for("bookshelf") { |code, content| code == 200 && content.includes?("A little less setup.") }
        log_path = File.join(p.root, "bookshelf-dev.log")
        builds = File.read(log_path).scan("Building bookshelf").size
        failures = File.read(log_path).scan(/Type check failed in \d+ ms/).size
        passes = File.read(log_path).scan(/Type check passed in \d+ ms/).size
        File.write(controller, original.sub("def handle(contract : Contract)\n", "def handle(contract : Contract)\n      tier_one_probe = 1 + \"two\"\n"))
        body = wait_for("bookshelf") { |code, content| code == 503 && content.includes?("app/actions/home/show.cr") }
        assert!(body.includes?("to &#39;Int32#+&#39;") && body.includes?("not String"), body[Math.max(0, body.size - 3000)..])
        assert!(Checks.wait_until(5.seconds, 50.milliseconds) { File.read(log_path).scan(/Type check failed in \d+ ms/).size == failures + 1 }, "type error did not print Type check failed")
        assert!(File.read(log_path).scan("Building bookshelf").size == builds, "type error reached code generation")
        assert!(site("bookshelf")["state"].as_s == "build-error")
        File.write(controller, original + "\n# Tier-1 recovery proof\n")
        wait_for("bookshelf") { |code, content| code == 200 && content.includes?("A little less setup.") }
        assert!(File.read(log_path).scan(/Type check passed in \d+ ms/).size > passes, "fixed source did not print Type check passed")
        assert!(File.read(log_path).scan("Building bookshelf").size == builds + 1, "fixed source did not build once")
        puts "PASS: Tier-1 type check shows a planted type error without code generation, then the fix type-checks and builds"
        diagnostic_headers = ["X-Diagnostic-Proof: 1"]
        File.write(controller, original.sub("def handle(contract : Contract)\n", "def handle(contract : Contract)\n      raise \"runtime-diagnostic-proof <escaped>\" if request.headers[\"X-Diagnostic-Proof\"]? == \"1\"\n"))
        assert!(File.read(controller) != original)
        body = wait_for("bookshelf", headers: diagnostic_headers) { |code, content| code == 500 && content.includes?("CARAMEL DEVELOPMENT EXCEPTION") }
        assert!(body.includes?("runtime-diagnostic-proof &lt;escaped&gt;") && body.includes?("app/actions/home/show.cr:"), body[0, Math.min(16000, body.size)])
        assert!(body.split("<details>")[0].includes?("app/actions/home/show.cr:"), body[0, Math.min(16000, body.size)])
        assert!(body.includes?("Internal stack frames"))
        assert!(site("bookshelf")["state"].as_s == "running")
        wait_for("bookshelf") { |code, content| code == 200 && content.includes?("A little less setup.") }
        status, state = request("bookshelf", "/__caramel/dev/status", ["X-Caramel-Dev: 1"])
        assert!(status == 200 && JSON.parse(state)["generation"].as_i64 > initial_generation)

        source = File.join(project, "app/assets/stylesheets/app.css")
        before = File.read(log_path).scan("Build ready").size
        checks = File.read(log_path).scan("Type check").size
        File.write(source, File.read(source) + "\n/* dev-asset-refresh-proof */\n")
        assert!(Checks.wait_until(8.seconds, 100.milliseconds) { request("bookshelf", "/assets/app.css")[1].includes?("dev-asset-refresh-proof") }, "asset changes did not publish")
        sleep 500.milliseconds
        assert!(File.read(log_path).scan("Build ready").size == before && File.read(log_path).scan("Type check").size == checks, "CSS triggered a Crystal compile")
        destination = File.join(project, "public/assets/app.css")
        File.write(destination, "A public edit that must be preserved")
        wait_for("bookshelf") { |code, content| code == 503 && content.includes?("Asset output conflict") }
        assert!(File.read(destination) == "A public edit that must be preserved")
        File.write(destination, File.read(source))
        wait_for("bookshelf") { |code, content| code == 200 && content.includes?("A little less setup.") }

        finish(first)
        current = site("bookshelf")
        assert!(current["upstream"].raw.nil?)
        assert!(current["state"].as_s == "stopped" && current["owner"].raw.nil?)
        assert!(request("bookshelf")[0] == 503)
        assert!(request("bookshelf-clone")[0] == 200)
        assert!(p.rpc("GET", "/v1/status")["services"].as_h.values.all? { |item| item["state"].as_s == "running" })

        restarted = start(project, "bookshelf")
        wait_for("bookshelf") { |code, content| code == 200 && content.includes?("A little less setup.") }
        assert!(Checks.wait_until(5.seconds, 50.milliseconds) { File.read(log_path).includes?("Build ready (cached)") })
        status, body = request("bookshelf", headers: diagnostic_headers)
        assert!(status == 500 && body.split("<details>")[0].includes?("app/actions/home/show.cr:"), body[0, Math.min(16000, body.size)])
        listing = p.command(["/bin/ps", "-ax", "-o", "pid=,args="], echo: false).stdout
        native_pids = listing.lines.compact_map do |line|
          parts = line.strip.split(/\s+/, 2)
          parts[0].to_i64? if parts.size == 2 && parts[1].starts_with?(File.join(project, ".caramel/dev/application-"))
        end
        assert!(native_pids.size == 1, "expected one owned native app")
        restarted.terminate(graceful: false)
        FrappeProject.wait_exit(restarted, 5.seconds, "killed terminal owner")
        @processes.delete(restarted)
        assert!(Checks.wait_until(8.seconds, 50.milliseconds) do
          native_pids.all? do |pid|
            info = p.attempt(["/bin/ps", "-p", pid.to_s, "-o", "stat=,args="], timeout: 5.seconds).stdout.strip
            info.empty? || info.starts_with?('Z') || !info.includes?(File.join(project, ".caramel/dev/application-"))
          end
        end, "native app survived terminal owner death")
        restarted = start(project, "bookshelf")
        wait_for("bookshelf") { |code, content| code == 200 && content.includes?("A little less setup.") }
        assert!(request("bookshelf-clone")[0] == 200)
        finish(restarted)
        build_directory = File.join(project, ".caramel/dev")
        debug_files = Dir.glob(File.join(build_directory, "application-*.dwarf"))
        assert!(debug_files.size == 1, debug_files.to_s)
        assert!(Dir.glob(File.join(build_directory, "building-*")).empty?)
        File.delete(debug_files[0])
        start(project, "bookshelf")
        body = wait_for("bookshelf", headers: diagnostic_headers) { |code, content| code == 500 && content.includes?("CARAMEL DEVELOPMENT EXCEPTION") }
        assert!(body.split("<details>")[0].includes?("app/actions/home/show.cr:"), body[0, Math.min(16000, body.size)])
        assert!(File.file?(debug_files[0]))
        assert!(!File.read(log_path).includes?("Build ready (cached)"))
        finish(clone_session)
        branched = start(@clone, "bookshelf-clone", runtime_url: branch_url)
        wait_for("bookshelf-clone") { |code, content| code == 503 && content.includes?("Pending migrations") }
        finish(branched)
        p.command([File.join(p.repo, "bin/frappe"), "db", "branch", "delete", "unmigrated"], chdir: @clone, echo: false)
        puts "PASS: a runtime URL override runs the migrated clone against its unmigrated Latte branch, whose pending migration shows"
        puts "PASS: runtime application locations, cached traces, missing debug-file recovery, and live CLI/native menu state"
        puts "PASS: cached restart, abrupt terminal death cleanup, stale socket recovery, and asset-conflict recovery"
        puts "PASS: watched native builds, same-origin diagnostics/recovery, pending-migration recovery, authenticated refresh, CSS without compilation, duplicate session refusal, and independent project shutdown"
      ensure
        @processes.each { |process| Checks.stop(process, 20.seconds) unless process.terminated? }
        @logs.each(&.close)
      end
    end
  end
end
