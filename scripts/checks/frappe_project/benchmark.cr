require "set"
require "c/fcntl"

module Caramel::Checks
  class FrappeProject::Benchmark
    class ProcessSampler
      getter rows : Array(JSON::Any)
      property phase : String
      property dev_pid : Int64?

      def initialize(@daemon_pid : Int64)
        @dev_pid = nil
        @phase = "setup"
        @rows = [] of JSON::Any
        @stop = Channel(Nil).new(1)
        @done = Channel(Nil).new(1)
      end

      def start : Nil
        spawn do
          loop do
            select
            when @stop.receive
              break
            when timeout(500.milliseconds)
              collect
            end
          end
        ensure
          @done.send(nil)
        end
      end

      def stop : Nil
        @stop.send(nil)
        select
        when @done.receive
        when timeout(7.seconds)
        end
      end

      private def collect : Nil
        result = Checks.run(["/bin/ps", "-ax", "-o", "pid=,ppid=,%cpu=,rss="], timeout: 5.seconds)
        return unless result.success?
        processes = {} of Int64 => {Int64, Float64, Int64}
        result.stdout.each_line do |line|
          parts = line.split
          next unless parts.size == 4
          pid = parts[0].to_i64?
          parent = parts[1].to_i64?
          cpu = parts[2].to_f64?
          rss = parts[3].to_i64?
          processes[pid] = {parent, cpu, rss} if pid && parent && cpu && rss
        end
        row = JSON.parse({phase: @phase, monotonic_seconds: Time.monotonic.total_seconds, services: usage(processes, @daemon_pid), development: usage(processes, @dev_pid)}.to_json)
        @rows << row
      end

      private def usage(processes : Hash(Int64, {Int64, Float64, Int64}), root : Int64?)
        owned = Set(Int64).new
        owned << root if root
        loop do
          descendants = processes.select { |_pid, values| owned.includes?(values[0]) }.keys
          fresh = descendants.reject { |pid| owned.includes?(pid) }
          break if fresh.empty?
          fresh.each { |pid| owned << pid }
        end
        values = processes.select { |pid, _values| owned.includes?(pid) }.values
        {processes: values.size, summed_rss_kib: values.sum(0_i64) { |value| value[2] }, summed_ps_cpu_percent: values.sum(0.0) { |value| value[1] }}
      end
    end

    @process : Process?
    @log : File?

    def initialize(@fixture : FrappeProject, @edit_only : Bool = false)
      @process = nil
      @log = nil
      @executable = File.join(@fixture.root, "dev-benchmark-fixture")
      @certificate = File.join(@fixture.root, "state/services/caddy/storage/pki/authorities/caramel/root.crt")
      @sampler = ProcessSampler.new(@fixture.daemon.not_nil!.pid.to_i64)
    end

    private def assert!(condition : Bool, message : String = "benchmark assertion failed") : Nil
      @fixture.assert!(condition, message)
    end

    private def json(value) : JSON::Any
      JSON.parse(value.to_json)
    end

    private def elapsed(& : ->) : Float64
      started = Time.monotonic
      yield
      (Time.monotonic - started).total_milliseconds
    end

    private def request(path : String) : {Int32, String}
      p = @fixture
      result = p.attempt(["/usr/bin/curl", "--silent", "--show-error", "--max-time", "5", "--noproxy", "*", "--cacert", @certificate, "--resolve", "bookshelf.caramel:#{p.ports[2]}:127.0.0.1", "-H", "Host: bookshelf.caramel", "--write-out", "\n%{http_code}", "https://bookshelf.caramel:#{p.ports[2]}#{path}"], timeout: 8.seconds)
      index = result.stdout.rindex('\n')
      return {0, result.stdout} unless index
      {result.stdout[(index + 1)..].strip.to_i? || 0, result.stdout[0...index]}
    end

    private def visible(path : String, marker : String, timeout : Time::Span = 120.seconds) : Nil
      deadline = Time.instant + timeout
      status = 0
      while Time.instant < deadline
        assert!(@process.try { |item| !item.terminated? } == true, "development owner exited")
        status, body = request(path)
        return if status == 200 && body.includes?(marker)
        sleep 50.milliseconds
      end
      raise "Timed out waiting for benchmark content: HTTP #{status}"
    end

    private def start(scenario : String) : Nil
      @log = File.open(File.join(@fixture.root, "#{scenario}-benchmark.log"), "a")
      @process = Process.new(@executable, [@fixture.project], chdir: @fixture.project, env: @fixture.env, output: @log.not_nil!, error: @log.not_nil!)
      @sampler.dev_pid = @process.not_nil!.pid.to_i64
    end

    private def stop : Nil
      if process = @process
        process.terminate unless process.terminated?
        status = FrappeProject.wait_exit(process, 25.seconds, "benchmark development owner")
        assert!(status.success?, "benchmark development owner did not exit cleanly")
        @process = nil
      end
      @sampler.dev_pid = nil
      @log.try(&.close)
      @log = nil
    end

    private def distribution(samples : Array(Float64)) : JSON::Any
      ordered = samples.sort
      midpoint = samples.size // 2
      json({samples_ms: samples, count: samples.size, median_ms: (ordered[midpoint - 1] + ordered[midpoint]) / 2, p95_ms: ordered[(samples.size * 0.95).ceil.to_i - 1], min_ms: ordered.first, max_ms: ordered.last})
    end

    private def persist(output : IO::FileDescriptor, report : JSON::Any) : Nil
      report.as_h["resource_samples"] = json(@sampler.rows)
      output.seek(0)
      output.print(report.to_pretty_json, '\n')
      output.flush
      raise "Cannot truncate benchmark report" unless LibC.ftruncate(output.fd, output.tell) == 0
      output.fsync
    end

    def check : Nil
      p = @fixture
      destination = ENV["CARAMEL_BENCHMARK_OUTPUT"]? || "/private/tmp/caramel-dev-benchmark-#{Time.utc.to_unix_ns}.json"
      fd = LibC.open(destination, LibC::O_RDWR | LibC::O_CREAT | LibC::O_EXCL | LibC::O_NOFOLLOW, 0o600)
      raise "Could not create benchmark report (destination exists or unavailable): #{destination}" if fd < 0
      output = IO::FileDescriptor.new(fd)
      version = File.read(File.join(p.repo, "tools/toolchain/caramel-toolchain.toml"))
      release = p.attempt(["/usr/bin/sw_vers", "-productVersion"]).stdout.strip
      arch = p.attempt(["/usr/bin/uname", "-m"]).stdout.strip
      platform = "macOS-#{release}-#{arch}-#{arch == "arm64" ? "arm-64bit" : "64bit"}"
      report = json({complete: false, mode: @edit_only ? "edit-only" : "full", scenarios: {} of String => JSON::Any, hardware: {} of String => JSON::Any, resource_samples: @sampler.rows,
                     limitations: ["HTTP-visible changes, not browser paint or browser refresh execution", "50 ms polling plus a new curl process per observation", "Managed compiler cache and dependencies warmed by fixture setup", "Summed RSS double-counts shared pages; ps CPU is a process-lifetime average", "Resource sampling every 500 ms can miss short-lived processes", "Private HTTPS ports and explicitly supplied fixture CA; no system DNS/trust acceptance"],
                     versions_manifest: version, platform: platform, sample_count_per_edit_kind: 20})
      # ameba:disable Lint/UselessAssign -- read by the ensure below
      sampler_started = false
      begin
        %w[hw.model hw.memsize hw.ncpu machdep.cpu.brand_string].each do |key|
          result = p.attempt(["/usr/sbin/sysctl", "-n", key])
          report["hardware"].as_h[key] = json(result.success? ? result.stdout.strip : "unavailable")
        end
        report.as_h["revision"] = json(p.command(["git", "rev-parse", "HEAD"], echo: false).stdout.strip)
        p.command([File.join(p.repo, "scripts/crystal"), "build", "spec/fixtures/frappe_dev.cr", "-o", @executable])
        @sampler.start
        sampler_started = true
        controller = File.join(p.project, "app/actions/home/show.cr")
        original_controller = File.read(controller)
        view = File.join(p.project, "app/views/home/index.cr")
        original_view = File.read(view)
        {"bookshelf" => 2, "larger" => 22}.each do |scenario, resources|
          metrics = json({generated_resources: resources, edits: {} of String => JSON::Any})
          report["scenarios"].as_h[scenario] = metrics
          if scenario == "larger"
            @sampler.phase = "larger/generation"
            "ABCDEFGHIJKLMNOPQRST".each_char do |letter|
              p.command([File.join(p.repo, "bin/frappe"), "make", "resource", "Benchmark#{letter}", "title:string", "description:string"], chdir: p.project)
            end
            metrics.as_h["migration_command_ms"] = json(elapsed { p.command([File.join(p.repo, "bin/frappe"), "migrate"], chdir: p.project) })
          end
          @sampler.phase = "#{scenario}/first-dev-build"
          metrics.as_h["first_dev_ready_ms"] = json(elapsed { start(scenario); visible("/", "A little less setup.") })
          {"css" => {File.join(p.project, "app/assets/stylesheets/app.css"), "/assets/app.css"},
           "javascript" => {File.join(p.project, "app/assets/javascript/app.js"), "/assets/app.js"},
           "view" => {view, "/"}, "crystal" => {controller, "/"}}.each do |kind, pair|
            path, url = pair
            @sampler.phase = "#{scenario}/#{kind}"
            before = File.read(path)
            samples = [] of Float64
            20.times do |index|
              marker = "benchmark-#{scenario}-#{kind}-#{index}"
              updated = case kind
                        when "crystal"
                          original_controller.sub(%(Views::Home::Index.new), %(Views::Home::Index.new.to_s + "<!-- #{marker} -->"))
                        when "view"
                          original_view.sub(%(section class: "welcome-grid"), %(comment #{marker.to_json}\n      section class: "welcome-grid"))
                        else
                          before + "\n/* #{marker} */\n"
                        end
              assert!(updated != original_controller) if kind == "crystal"
              assert!(updated != original_view) if kind == "view"
              samples << elapsed { File.write(path, updated); visible(url, marker) }
            end
            data = distribution(samples)
            metrics["edits"].as_h[kind] = data
            puts "MEASURED #{scenario} #{kind}: median=#{data["median_ms"].as_f.round.to_i} ms p95=#{data["p95_ms"].as_f.round.to_i} ms"
            persist(output, report)
          end
          stop
          @sampler.phase = "#{scenario}/cached-start"
          metrics.as_h["cached_dev_ready_ms"] = json(elapsed { start(scenario); visible("/", "benchmark-#{scenario}-crystal-19") })
          stop
          artifacts = {} of String => Int64
          Dir.glob(File.join(p.project, ".caramel/dev/application-*")).each do |item|
            suffix = File.extname(item)
            artifacts[suffix.empty? ? "binary" : suffix] = File.size(item)
          end
          metrics.as_h["development_artifacts_bytes"] = json(artifacts)
          if @edit_only
            persist(output, report)
            next
          end
          @sampler.phase = "#{scenario}/semantic-check"
          metrics.as_h["semantic_check_ms"] = json(elapsed { p.command([File.join(p.repo, "scripts/crystal"), "build", "src/bookshelf.cr", "--no-codegen"], chdir: p.project) })
          @sampler.phase = "#{scenario}/specs"
          metrics.as_h["spec_command_ms"] = json(elapsed { p.command([File.join(p.repo, "bin/frappe"), "corretto"], chdir: p.project, timeout: 600.seconds) })
          @sampler.phase = "#{scenario}/release-build"
          release_binary = File.join(p.root, "#{scenario}-release")
          metrics.as_h["release_build_ms"] = json(elapsed { p.command([File.join(p.repo, "scripts/crystal"), "build", "src/bookshelf.cr", "--release", "-o", release_binary], chdir: p.project) })
          metrics.as_h["release_binary_bytes"] = json(File.size(release_binary))
          persist(output, report)
        end
        report.as_h["complete"] = json(true)
        puts "Performance report: #{destination}"
      ensure
        begin
          stop
        ensure
          @sampler.stop if sampler_started
          persist(output, report)
          output.close
          puts "Saved performance evidence (complete=#{report["complete"].as_bool}): #{destination}"
        end
      end
    end
  end
end
