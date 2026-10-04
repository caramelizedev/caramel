require "./support/unix_http"
require "../../src/latte/postgres"
require "../../src/latte/control_api"

lib LibC
  fun getsid(pid : PidT) : PidT
end

module Caramel::Checks::LatteDaemon
  extend self

  LATTE  = File.join(Checks::REPO, "bin/latte")
  FRAPPE = File.join(Checks::REPO, "bin/frappe")

  private def request(socket : String,
                      method : String,
                      path : String,
                      body : JSON::Any? = nil) : JSON::Any
    Checks::UnixHTTP.json!(socket, method, path, body, timeout: 20.seconds)
  end

  private def wait_state(socket : String, state : String) : Nil
    deadline = Time.instant + 60.seconds
    loop do
      begin
        result = request(socket, "GET", "/v1/status")
        states = result["services"].as_h.values.map(&.["state"].as_s)
        return if states == [state, state, state]
        raise result.to_json if states.includes?("failed")
      rescue Socket::Error | IO::Error
      end
      raise "Services did not become #{state}" if Time.instant >= deadline
      sleep 100.milliseconds
    end
  end

  private def dns_ready!(domain : String) : Nil
    query = IO::Memory.new
    query.write(Bytes[0x43, 0x41, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
    domain.split('.').each do |label|
      query.write_byte(label.bytesize.to_u8)
      query << label
    end
    query.write(Bytes[0, 0, 1, 0, 1])
    dns = UDPSocket.new
    dns.read_timeout = 1.second
    dns.connect("127.0.0.1", 15353)
    dns.send(query.to_slice)
    answer = Bytes.new(512)
    count, _ = dns.receive(answer)
    # The low four bits of the fourth byte are the response code.
    no_error = count >= 4 && (answer[3] & 15) == 0
    loopback = no_error && answer[count - 4, 4] == Bytes[127, 0, 0, 1]
    raise "Registration returned before DNS was ready" unless loopback
  ensure
    dns.try(&.close)
  end

  # The record is rewritten while the supervisor restarts Caddy; a missing
  # record means the restart has not finished yet.
  private def caddy_pid(root : String) : Int64?
    JSON.parse(File.read(File.join(root, "services/caddy/process.json")))["pid"].as_i64
  rescue File::NotFoundError
    nil
  end

  private def launch(root : String, log : File, environment : Hash(String, String?)) : Process
    Process.new([LATTE, "daemon"],
      env: environment, output: log, error: log, input: Process::Redirect::Close)
  end

  # The process holding the daemon's instance lock.
  private def daemon_pid(root : String) : Int64
    lock = File.join(Caramel::Latte::Paths.new(root).run_dir, "daemon.lock")
    holders = Checks.run(["/usr/sbin/lsof", "-t", "--", lock], timeout: 10.seconds).stdout.split
    raise "Expected one process holding #{lock}, found #{holders}" unless holders.size == 1
    holders.first.to_i64
  end

  # Runs *sql* as Latte's PostgreSQL administrator over the private socket.
  private def admin(root : String, runtime : String, sql : String) : String
    toolchain = Caramel::Latte::Toolchain.new(Caramel::Checks.toolchain_root)
    secret = File.read(File.join(root, "secrets/postgres-admin.json"))
    password = JSON.parse(secret)["password"].as_s
    passfile = File.join(root, "check-admin.pgpass")
    File.write(passfile, "*:*:*:#{Caramel::Latte::Postgres::ADMIN_USER}:#{password}\n", perm: 0o600)
    psql = [toolchain.psql, "-X", "-v", "ON_ERROR_STOP=1", "-A", "-t",
            "-h", File.join(runtime, "postgres"),
            "-U", Caramel::Latte::Postgres::ADMIN_USER, "-d", "postgres"]
    env = toolchain.environment({"PGPASSFILE" => passfile})
    result = Checks.run(psql, env: env, input: sql, timeout: 10.seconds)
    raise "Administrator query failed: #{result.stderr}" unless result.success?
    result.stdout.strip
  ensure
    File.delete?(passfile) if passfile
  end

  # Leaves *database* the way a guard interrupted before its release would.
  private def strand_guard(root : String, runtime : String, database : String) : Nil
    name = Caramel::Latte::Postgres.quote_identifier(database)
    admin(root, runtime, "ALTER DATABASE #{name} WITH ALLOW_CONNECTIONS false;")
    allowed = connections_allowed(root, runtime, database)
    raise "Could not disable connections to #{database}" unless allowed == "f"
  end

  private def connections_allowed(root : String, runtime : String, database : String) : String
    name = Caramel::Latte::Postgres.quote_literal(database)
    admin(root, runtime, "SELECT datallowconn FROM pg_database WHERE datname = #{name};")
  end

  def main : Int32
    unless File.file?(LATTE) && File.file?(FRAPPE)
      Checks.fail("run scripts/build-latte and scripts/build-frappe first")
    end
    base = Checks.private_temp("latte-daemon-")
    home = File.join(base, "home")
    # The per-user state a plain `frappe` or `latte` uses under this HOME.
    # Most phases name it with CARAMEL_HOME; the on-demand phase does not.
    root = File.join(home, "Library/Application Support/Caramel")
    Dir.mkdir_p(root, 0o700)
    runtime = Checks.runtime_root(root)
    socket = File.join(runtime, "latte.sock")
    environment = {"CARAMEL_HOME" => root} of String => String?
    user = {"HOME" => home, "CARAMEL_HOME" => nil} of String => String?
    log = File.open(File.join(root, "daemon.log"), "a", 0o600)
    process : Process? = nil
    begin
      process = launch(root, log, environment)
      wait_state(socket, "running")
      # ADR 0016: Latte reports its release and the control API window it serves.
      status = request(socket, "GET", "/v1/status")
      window = Caramel::Latte::ControlAPI::VERSIONS
      release = status["latte"] == Caramel::VERSION
      unless release && status["api"].as_a.map(&.as_i) == window
        raise "Latte does not report its release and API window: #{status.to_json}"
      end
      reported = Checks.run([LATTE, "version"], env: environment)
      unless reported.stdout == "Latte #{Caramel::VERSION} (control API 1, 2)\n"
        raise "latte version printed #{reported.stdout.inspect}"
      end
      duplicate = Checks.run([LATTE, "daemon"], env: environment, timeout: 5.seconds)
      raise "Two daemons acquired the same instance" if duplicate.success?
      registration = JSON.parse({name: "bookshelf", directory: root}.to_json)
      site = request(socket, "POST", "/v1/sites", registration)["site"]
      dns_ready!(site["domain"].as_s)
      before = caddy_pid(root) || raise "Caddy has no process record after startup"
      database = Caramel::Latte::Postgres.database_names(site["id"].as_s).development
      strand_guard(root, runtime, database)
      process.terminate
      raise "Daemon did not exit cleanly on SIGTERM" unless process.wait.success?
      allowed = connections_allowed(root, runtime, database)
      raise "SIGTERM left #{database} refusing connections" unless allowed == "t"
      process = launch(root, log, environment)
      wait_state(socket, "running")
      strand_guard(root, runtime, database)
      process.terminate(graceful: false)
      process.wait
      allowed = connections_allowed(root, runtime, database)
      raise "A killed daemon cannot release guards" unless allowed == "f"
      process = launch(root, log, environment)
      wait_state(socket, "running")
      allowed = connections_allowed(root, runtime, database)
      unless allowed == "t"
        raise "Restart after SIGKILL left #{database} refusing connections"
      end
      after = caddy_pid(root) || raise "Caddy has no process record after daemon restart"
      raise "Daemon restart should adopt its verified service" unless before == after
      registered = request(socket, "GET", "/v1/sites")["sites"].as_a.first
      raise "Site registry was not preserved" unless registered["id"] == site["id"]
      certificate_path = File.join(root, "services/caddy/storage/pki/authorities/caramel/root.crt")
      certificate = File.read(certificate_path)
      Process.signal(Signal::KILL, after)
      deadline = Time.instant + 15.seconds
      loop do
        break if (current = caddy_pid(root)) && current != after
        raise "Proxy crash was not recovered automatically" if Time.instant >= deadline
        sleep 100.milliseconds
      end
      wait_state(socket, "running")
      raise "Proxy CA was not preserved" unless File.read(certificate_path) == certificate
      latte_app = File.join(Checks::REPO, "bin/Latte.app/Contents/MacOS/Latte")
      menu = Checks.run([latte_app, "--check"], env: environment, timeout: 10.seconds)
      raise menu.stdout + menu.stderr unless menu.success?
      recovered = caddy_pid(root) || raise "Caddy has no process record after recovery"
      Process.signal(Signal::KILL, recovered)
      deadline = Time.instant + 10.seconds
      loop do
        status = request(socket, "GET", "/v1/status")
        if status["services"]["proxy"]["state"].as_s == "failed"
          raise status.to_json unless status["error"]?.try(&.as_s.includes?("Start Services"))
          break
        end
        raise "Second crash was not diagnosed" if Time.instant >= deadline
        sleep 100.milliseconds
      end
      request(socket, "POST", "/v1/services/start", JSON.parse("{}"))
      wait_state(socket, "running")
      request(socket, "POST", "/v1/services/stop", JSON.parse("{}"))
      wait_state(socket, "stopped")
      pg_version = File.join(root, "services/postgres/18/data/PG_VERSION")
      raise "PostgreSQL cluster was not retained" unless File.exists?(pg_version)
      process.terminate
      raise "Daemon did not exit cleanly on SIGTERM" unless process.wait.success?
      # With no daemon running, Frappé starts `latte daemon --detach`, which
      # outlives Frappé in a session of its own and logs privately.
      started = Checks.run([FRAPPE, "services", "start"], env: user, timeout: 150.seconds)
      backgrounded = started.stderr.includes?("Started Latte in the background")
      raise started.stdout + started.stderr unless started.success? && backgrounded
      wait_state(socket, "running")
      detached = daemon_pid(root)
      raise "Frappé's Latte shares a session with Frappé" unless LibC.getsid(detached) == detached
      log_mode = File.info(File.join(root, "logs/latte.log")).permissions.value
      raise "Detached Latte has no private log" unless log_mode == 0o600
      request(socket, "POST", "/v1/services/stop", JSON.parse("{}"))
      wait_state(socket, "stopped")
      stopped = Checks.run([LATTE, "stop"], env: user, timeout: 30.seconds)
      confirmed = stopped.stdout.includes?("Latte stopped")
      raise stopped.stdout + stopped.stderr unless stopped.success? && confirmed
      exited = Checks.wait_until(5.seconds, 50.milliseconds) do
        !Process.exists?(detached)
      end
      raise "latte stop left the daemon running" unless exited
      idle = Checks.run([LATTE, "stop"], env: user, timeout: 10.seconds)
      not_running = idle.stdout.includes?("Latte is not running")
      raise idle.stdout + idle.stderr unless idle.success? && not_running
      puts "PASS: daemon singleton, crash recovery, service adoption, " \
           "guard release on SIGTERM and on restart after SIGKILL, proxy recovery, " \
           "CA/registry persistence, native menu, explicit stop, " \
           "on-demand detached start from Frappé and latte stop"
      0
    rescue ex
      STDERR.puts ex.message
      1
    ensure
      # A detached daemon from the on-demand phase must not outlive the check.
      Checks.run([LATTE, "stop"], env: user, timeout: 30.seconds)
      # A failure while the daemon is down would otherwise leave services running.
      postmaster = File.join(root, "services/postgres/18/data/postmaster.pid")
      if process && process.terminated? && File.exists?(postmaster)
        process = launch(root, log, environment)
      end
      if process && !process.terminated?
        begin
          # A failed assertion can land during automatic recovery; wait for
          # that operation instead of leaving services behind.
          stop_deadline = Time.instant + 60.seconds
          loop do
            request(socket, "POST", "/v1/services/stop", JSON.parse("{}"))
            break
          rescue ex
            raise ex if Time.instant >= stop_deadline
            sleep 250.milliseconds
          end
          wait_state(socket, "stopped")
        rescue ex
          puts "Cleanup needs inspection: #{root}: #{ex.message}"
        end
        Checks.stop(process)
      end
      log.close
      if File.exists?(postmaster)
        puts "Preserved running cluster state: #{root}"
      else
        FileUtils.rm_rf(runtime) if Dir.exists?(runtime)
        FileUtils.rm_rf(base)
      end
    end
  end
end

exit Caramel::Checks::LatteDaemon.main
