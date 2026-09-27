require "./support/unix_http"

module Caramel::Checks::LatteDaemon
  extend self

  private def request(socket : String, method : String, path : String, body : JSON::Any? = nil) : JSON::Any
    Checks::UnixHTTP.json!(socket, method, path, body, timeout: 20.seconds)
  end

  private def wait_state(socket : String, state : String) : Nil
    deadline = Time.instant + 60.seconds
    loop do
      begin
        result = request(socket, "GET", "/v1/status")
        states = result["services"].as_h.values.map { |entry| entry["state"].as_s }
        return if states == [state, state, state]
        raise result.to_json if states.includes?("failed")
      rescue ex : Socket::Error | IO::Error
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
    raise "Registration returned before DNS was ready" unless count >= 4 && (answer[3] & 15) == 0 && answer[count - 4, 4] == Bytes[127, 0, 0, 1]
  ensure
    dns.try(&.close)
  end

  private def caddy_pid(root : String) : Int64
    JSON.parse(File.read(File.join(root, "services/caddy/process.json")))["pid"].as_i64
  end

  private def launch(root : String, log : File, environment : Hash(String, String?)) : Process
    Process.new([File.join(Checks::REPO, "bin/latte"), "daemon"], env: environment, output: log, error: log, input: Process::Redirect::Close)
  end

  def main : Int32
    root = Checks.private_temp("latte-daemon-")
    runtime = Checks.runtime_root(root)
    socket = File.join(runtime, "latte.sock")
    environment = {"CARAMEL_HOME" => root} of String => String?
    log = File.open(File.join(root, "daemon.log"), "a", 0o600)
    process : Process? = nil
    begin
      process = launch(root, log, environment)
      wait_state(socket, "running")
      duplicate = Checks.run([File.join(Checks::REPO, "bin/latte"), "daemon"], env: environment, timeout: 5.seconds)
      raise "Two daemons acquired the same instance" if duplicate.success?
      site = request(socket, "POST", "/v1/sites", JSON.parse({name: "bookshelf", directory: root}.to_json))["site"]
      dns_ready!(site["domain"].as_s)
      before = caddy_pid(root)
      process.terminate(graceful: false)
      process.wait
      process = launch(root, log, environment)
      wait_state(socket, "running")
      after = caddy_pid(root)
      raise "Daemon restart should adopt its verified service" unless before == after
      raise "Site registry was not preserved" unless request(socket, "GET", "/v1/sites")["sites"].as_a.first["id"] == site["id"]
      certificate_path = File.join(root, "services/caddy/storage/pki/authorities/caramel/root.crt")
      certificate = File.read(certificate_path)
      Process.signal(Signal::KILL, after)
      deadline = Time.instant + 15.seconds
      loop do
        break if caddy_pid(root) != after
        raise "Proxy crash was not recovered automatically" if Time.instant >= deadline
        sleep 100.milliseconds
      end
      wait_state(socket, "running")
      raise "Proxy CA was not preserved" unless File.read(certificate_path) == certificate
      menu = Checks.run([File.join(Checks::REPO, "bin/Latte.app/Contents/MacOS/Latte"), "--check"], env: environment, timeout: 10.seconds)
      raise menu.stdout + menu.stderr unless menu.success?
      Process.signal(Signal::KILL, caddy_pid(root))
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
      raise "PostgreSQL cluster was not retained" unless File.exists?(File.join(root, "services/postgres/18/data/PG_VERSION"))
      puts "PASS: daemon singleton, crash recovery, service adoption, proxy recovery, CA/registry persistence, native menu and explicit stop"
      0
    rescue ex
      STDERR.puts ex.message
      1
    ensure
      if process && !process.terminated?
        begin
          request(socket, "POST", "/v1/services/stop", JSON.parse("{}"))
          wait_state(socket, "stopped")
        rescue ex
          puts "Cleanup needs inspection: #{root}: #{ex.message}"
        end
        Checks.stop(process)
      end
      log.close
      if File.exists?(File.join(root, "services/postgres/18/data/postmaster.pid"))
        puts "Preserved running cluster state: #{root}"
      else
        FileUtils.rm_rf(runtime) if Dir.exists?(runtime)
        FileUtils.rm_rf(root)
      end
    end
  end
end

exit Caramel::Checks::LatteDaemon.main
