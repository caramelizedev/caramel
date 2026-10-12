require "./support/harness"
require "uri"

# SweetTalk's jobs worked by `work` in two OS processes (ADRs 0019 and 0030):
# the rules domain's tally steps each run once, both processes claim them,
# every Tally total is the sum of its steps, and SIGTERM lets an in-flight step
# finish. It builds spec/fixtures/sweet_talk_workers.cr and owns a PostgreSQL
# cluster, as integration does.
module Caramel::Checks::SweetTalkWorkers
  extend self

  FIXTURE      = "spec/fixtures/sweet_talk_workers.cr"
  STEPS        =   50
  PAUSE_MS     =   50
  IN_FLIGHT_MS = 3000
  TALLIED      = "Rules::Shelf::Tally::WhenBoxTallied"

  private def required(argv : Array(String),
                       env : Hash(String, String?),
                       input : String? = nil) : Caramel::Latte::ProcessResult
    result = Checks.run(argv, env: env, input: input, timeout: 120.seconds)
    raise "Workers harness failed: TimeoutExpired" if result.timed_out?
    raise "Workers harness failed: #{result.stdout}#{result.stderr}" unless result.success?
    result
  end

  def main : Int32
    installs = File.join(File.realpath(Checks.toolchain_root), "data/installs")
    pg = File.join(installs, "conda-postgresql/18.6/bin")
    unless File.file?(File.join(pg, "initdb"))
      STDERR.puts "Managed PostgreSQL is missing; rerun scripts/install-toolchain."
      return 1
    end
    owned = Checks.private_temp("caramel-sweet-talk-workers-")
    data = File.join(owned, "data")
    sock = File.join(owned, "socket")
    Dir.mkdir(sock, 0o700)
    port = Checks.free_tcp_port
    env = Hash(String, String?).new
    ENV.each { |key, _| env[key] = nil if key.starts_with?("PG") }
    env["LC_ALL"] = "C"
    env["CARAMEL_EXPECTED_DATABASE_URL"] = nil
    env["CARAMEL_OPS_SOCKET"] = nil
    started = false
    failed = false
    begin
      required([File.join(pg, "initdb"), "-D", data, "--username=caramel_admin",
                "--encoding=UTF8", "--locale=C", "--auth-local=trust"], env)
      # Appended to initdb's configuration after a blank line.
      settings = <<-CONF

        listen_addresses = ''
        port = #{port}
        unix_socket_directories = '#{sock}'
        timezone = 'UTC'

        CONF
      File.open(File.join(data, "postgresql.conf"), "a") do |config|
        config << settings
      end
      log = File.join(owned, "postgres.log")
      required([File.join(pg, "pg_ctl"), "-D", data, "-l", log, "-w", "start"], env)
      started = true
      required([File.join(pg, "psql"), "-X", "-v", "ON_ERROR_STOP=1",
                "-h", sock, "-p", port.to_s, "-U", "caramel_admin", "-d", "postgres",
                "-c", "CREATE DATABASE caramel_workers"], env)
      query = "host=#{URI.encode_www_form(sock)}&port=#{port}&sslmode=disable"
      url = "postgresql://caramel_admin:@/caramel_workers?#{query}"
      env["CARAMEL_ENV"] = "production"
      env["DATABASE_URL"] = url
      env["MIGRATION_DATABASE_URL"] = url
      scenario(owned, env)
    rescue ex : Exception
      STDERR.puts ex.message
      failed = true
    ensure
      if started || File.exists?(File.join(data, "postmaster.pid"))
        begin
          stop = [File.join(pg, "pg_ctl"), "-D", data, "-m", "fast", "-w", "stop"]
          stopped = Checks.run(stop, env: env, timeout: 30.seconds)
          if stopped.success?
            FileUtils.rm_rf(owned)
          else
            STDERR.puts "Could not stop owned PostgreSQL cluster; retained at #{owned}"
            failed = true
          end
        rescue ex
          STDERR.puts "Could not stop owned PostgreSQL cluster; retained at #{owned}: #{ex.message}"
          failed = true
        end
      else
        FileUtils.rm_rf(owned)
      end
    end
    failed ? 1 : 0
  end

  # The steps against the running cluster. A failed step raises, so `main`
  # still stops the cluster; the worker processes stop first.
  private def scenario(owned : String, env : Hash(String, String?)) : Nil
    binary = File.join(owned, "rules-workers")
    build = Checks.crystal(["build", FIXTURE, "-o", binary], timeout: 1.hour)
    raise build.stdout + build.stderr unless build.success?
    migrated = Checks.run([binary, "migrate"], env: env)
    raise "migrate failed: #{migrated.stdout}#{migrated.stderr}" unless migrated.success?

    logs = {"alpha" => File.join(owned, "alpha.log"), "beta" => File.join(owned, "beta.log")}
    workers = logs.transform_values do |path|
      File.open(path, "w") do |output|
        Process.new(binary, ["work", "--concurrency=2", "--no-scheduler"],
          env: env, input: Process::Redirect::Close, output: output, error: output)
      end
    end
    begin
      logs.each do |name, path|
        ready = Checks.wait_until(30.seconds, 50.milliseconds) do
          File.read(path).includes?("worker is ready")
        end
        raise "#{name} did not start: #{File.read(path)}" unless ready
      end
      steps(binary, env, logs, workers)
    ensure
      workers.each_value { |process| Checks.stop(process) }
    end
  end

  private def steps(binary : String,
                    env : Hash(String, String?),
                    logs : Hash(String, String),
                    workers : Hash(String, Process)) : Nil
    issue(binary, env, STEPS, PAUSE_MS)
    latest = nil
    finished = Checks.wait_until(60.seconds, 100.milliseconds) do
      latest = report(binary, env)
      latest["finished"] == STEPS
    end
    raise "the #{STEPS} tally steps did not finish within 60 s: #{latest}" unless finished
    progress = latest.not_nil!

    ran = logs.transform_values { |path| job_ids(path) }
    both = ran["alpha"] & ran["beta"]
    raise "a tally step ran in both processes: job ids #{both.join(", ")}" unless both.empty?
    union = ran["alpha"] | ran["beta"]
    raise "the logs name #{union.size} tally steps, not #{STEPS}" unless union.size == STEPS
    attempts = progress["max_attempts"].as_i
    raise "a tally step was claimed #{attempts} times" unless attempts == 1
    puts "PASS: two worker processes ran #{STEPS} tally steps, each once"

    ran.each do |name, ids|
      if ids.empty?
        raise "#{name} ran no tally step; SKIP LOCKED gave every step to one process"
      end
    end
    puts "PASS: both worker processes claimed tally steps " \
         "(alpha #{ran["alpha"].size}, beta #{ran["beta"].size})"

    totals = progress["totals"].as_a.map { |pair| pair.as_a.map(&.as_i64) }
    expected = (1_i64..10_i64).map { |box| [box, 105_i64 + 5 * (box - 1)] }
    raise "Tally totals #{totals}, expected #{expected}" unless totals == expected
    puts "PASS: every box's Tally total is the sum of its steps"

    sigterm(binary, env, workers)
  end

  private def sigterm(binary : String,
                      env : Hash(String, String?),
                      workers : Hash(String, Process)) : Nil
    Checks.stop(workers["beta"])
    issue(binary, env, 1, IN_FLIGHT_MS)
    latest = nil
    in_flight = Checks.wait_until(10.seconds, 50.milliseconds) do
      latest = report(binary, env)
      latest["locked"] == 1
    end
    raise "no tally step was in flight: #{latest}" unless in_flight
    alpha = workers["alpha"]
    alpha.terminate
    status = alpha.wait
    raise "work did not exit 0 after SIGTERM: #{status}" unless status.success?
    progress = report(binary, env)
    unless progress["finished"] == STEPS + 1 && progress["locked"] == 0
      raise "SIGTERM left the in-flight tally step unfinished: #{progress}"
    end
    puts "PASS: SIGTERM lets the in-flight tally step finish, then work exits 0"
  end

  private def issue(binary : String,
                    env : Hash(String, String?),
                    count : Int32,
                    pause : Int32) : Nil
    issued = Checks.run([binary, "issue", count.to_s, pause.to_s], env: env)
    raise "issue failed: #{issued.stdout}#{issued.stderr}" unless issued.success?
  end

  private def report(binary : String, env : Hash(String, String?)) : JSON::Any
    reported = Checks.run([binary, "report"], env: env)
    raise "report failed: #{reported.stdout}#{reported.stderr}" unless reported.success?
    JSON.parse(reported.stdout)
  end

  # The ids of the tally steps a worker's JSON job lines name.
  private def job_ids(log : String) : Array(Int64)
    File.read(log).lines.compact_map do |line|
      next unless line.starts_with?('{')
      entry = JSON.parse(line)
      next unless entry["msg"]? == "job" && entry["name"]? == TALLIED
      entry["job_id"].as_i64
    end
  end
end

exit Caramel::Checks::SweetTalkWorkers.main
