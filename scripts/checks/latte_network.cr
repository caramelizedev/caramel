require "./support/harness"

module Caramel::Checks::LatteNetwork
  extend self

  private def run!(args : Array(String), *, timeout : Time::Span = 30.seconds) : String
    result = Checks.run(args, timeout: timeout)
    raise "#{args.first} failed: #{result.stderr}" unless result.success?
    result.stdout
  end

  private def eventually(label : String, duration : Time::Span = 12.seconds, &block : -> String) : String
    deadline = Time.instant + duration
    loop do
      begin
        return yield
      rescue ex
        raise "#{label} did not become ready: #{ex.message}" if Time.instant >= deadline
        sleep 100.milliseconds
      end
    end
  end

  private def fake_application(server : UNIXServer, name : String, stop : Channel(Nil), done : Channel(Nil)) : Nil
    loop do
      break if stop.closed?
      peer = server.accept
      if stop.closed?
        peer.close
        break
      end
      spawn do
        begin
          if peer.gets
            while line = peer.gets
              break if line.strip.empty?
            end
            body = "<h1>#{name}</h1>"
            peer << "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
            peer.flush
          end
        rescue IO::Error
        ensure
          peer.close
        end
      end
    end
  rescue IO::Error
  ensure
    done.send(nil)
  end

  private def configure(fixture : String, root : String, mode : String, dns : Int32, https : Int32, http : Int32) : JSON::Any
    JSON.parse(run!([fixture, root, mode, dns.to_s, https.to_s, http.to_s]))
  end

  private def query(port : Int32, host : String, kind : String = "A", tcp : Bool = false, status : String = "NOERROR", answer : String? = nil) : String
    output = run!(["/usr/bin/dig", "@127.0.0.1", "-p", port.to_s, host, kind, "+time=1", "+tries=1", tcp ? "+tcp" : "+notcp"])
    raise output unless output.includes?("status: #{status}")
    raise output if answer && !output.includes?(answer)
    raise output if kind == "AAAA" && !output.includes?("ANSWER: 0")
    output
  end

  private def request(config : JSON::Any, name : String, port : Int32, expected : Int32 = 200, host : String? = nil) : String
    args = ["/usr/bin/curl", "--silent", "--show-error", "--max-time", "3", "--noproxy", "*", "--cacert", config["ca"].as_s,
            "--resolve", "#{name}.caramel:#{port}:127.0.0.1", "--write-out", "\n%{http_code}"]
    args.concat(["-H", "Host: #{host}"]) if host
    args << "https://#{name}.caramel:#{port}/"
    output = run!(args)
    raise output unless output.ends_with?("\n#{expected}")
    output
  end

  def main : Int32
    tool_root = File.realpath(Checks.toolchain_root)
    installs = File.join(tool_root, "data/installs")
    coredns = File.join(installs, "github-coredns-coredns/1.14.7/coredns")
    caddy = File.join(installs, "aqua-caddyserver-caddy/2.11.4/caddy")
    root = Checks.private_temp("latte network-")
    runtime = Checks.runtime_root(root)
    processes = [] of Process
    servers = [] of UNIXServer
    stop_signals = [] of Channel(Nil)
    finished = [] of Channel(Nil)
    logs = [] of File
    begin
      fixture = File.join(root, "network-fixture")
      result = Checks.crystal(["build", File.join(Checks::REPO, "spec/fixtures/latte_network.cr"), "-o", fixture], timeout: 30.seconds)
      raise result.stderr unless result.success?
      dns_port = Checks.free_udp_port
      https_port = Checks.free_tcp_port
      http_port = Checks.free_tcp_port
      config = configure(fixture, root, "prepare", dns_port, https_port, http_port)
      runtime = config["runtime"].as_s
      config["sites"].as_a.each do |site|
        server = UNIXServer.new(site["socket"].as_s)
        File.chmod(site["socket"].as_s, 0o600)
        servers << server
        stop_signal = Channel(Nil).new
        done = Channel(Nil).new(1)
        stop_signals << stop_signal
        finished << done
        spawn fake_application(server, site["name"].as_s, stop_signal, done)
      end
      config = configure(fixture, root, "route", dns_port, https_port, http_port)
      environment = Hash(String, String?).new
      ENV.each { |key, _| environment[key] = nil if key.starts_with?("CADDY_") }
      config["environment"].as_h.each { |key, value| environment[key] = value.as_s }
      {"dns" => [coredns, "-conf", config["corefile"].as_s], "proxy" => [caddy, "run", "--config", config["caddy_config"].as_s]}.each do |name, command|
        log = File.open(File.join(root, "#{name}.log"), "a", 0o600)
        logs << log
        processes << Process.new(command, env: environment, chdir: root, output: log, error: log, input: Process::Redirect::Close)
      end
      eventually("DNS") { query(dns_port, "bookshelf.caramel", answer: "127.0.0.1") }
      {false, true}.each do |tcp|
        query(dns_port, "bookshelf.caramel", tcp: tcp, answer: "127.0.0.1")
        query(dns_port, "notes.caramel", tcp: tcp, answer: "127.0.0.1")
        query(dns_port, "bookshelf.caramel", "AAAA", tcp: tcp)
        query(dns_port, "missing.caramel", tcp: tcp, status: "NXDOMAIN")
        query(dns_port, "example.com", tcp: tcp, status: "REFUSED")
      end
      {"bookshelf", "notes"}.each do |name|
        output = eventually("HTTPS #{name}") { request(config, name, https_port) }
        raise output unless output.includes?("<h1>#{name}</h1>")
      end
      redirect = run!(["/usr/bin/curl", "--silent", "--show-error", "--max-time", "3", "--noproxy", "*", "--dump-header", "-", "-H", "Host: bookshelf.caramel", "http://127.0.0.1:#{http_port}/books?q=novel"])
      raise redirect unless redirect.lines.first.includes?("308") && redirect.includes?("https://bookshelf.caramel:#{https_port}/books?q=novel")
      raise "Caddy admin socket is not private" unless File.info(config["admin"].as_s).permissions.value & 0o777 == 0o600
      request(config, "bookshelf", https_port, 421, "notes.caramel")
      request(config, "bookshelf", https_port, 421, "missing.caramel")
      ca_before = File.read(config["ca"].as_s)
      config = configure(fixture, root, "unregister", dns_port, https_port, http_port)
      run!(["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "5", "--unix-socket", config["admin"].as_s,
            "-H", "Content-Type: application/json", "--data-binary", "@#{config["caddy_config"].as_s}", "http://localhost/load"])
      eventually("DNS removal") { query(dns_port, "notes.caramel", status: "NXDOMAIN") }
      raise "Retained site unavailable" unless request(config, "bookshelf", https_port).includes?("<h1>bookshelf</h1>")
      request(config, "bookshelf", https_port, 421, "notes.caramel")
      removed = Checks.run(["/usr/bin/curl", "--silent", "--show-error", "--max-time", "3", "--noproxy", "*", "--cacert", config["ca"].as_s,
                            "--resolve", "notes.caramel:#{https_port}:127.0.0.1", "--write-out", "\n%{http_code}", "https://notes.caramel:#{https_port}/"], timeout: 30.seconds)
      raise "removed hostname still accepts TLS: #{removed.stdout} #{removed.stderr}" unless removed.status.exit_code == 35
      raise "CA changed after removal" unless File.read(config["ca"].as_s) == ca_before
      raise "Removed site's files were deleted" unless Dir.exists?(File.join(root, "notes"))
      Checks.stop(processes.last)
      processes << Process.new([caddy, "run", "--config", config["caddy_config"].as_s], env: environment, chdir: root, output: logs.last, error: logs.last, input: Process::Redirect::Close)
      eventually("HTTPS restart") { request(config, "bookshelf", https_port) }
      raise "CA changed after restart" unless File.read(config["ca"].as_s) == ca_before
      puts "Latte DNS UDP/TCP + two-site verified HTTPS + private administration + removal/restart: passed"
      0
    rescue ex
      STDERR.puts ex.message
      {"dns", "proxy"}.each do |name|
        path = File.join(root, "#{name}.log")
        if File.exists?(path)
          text = File.read(path)
          STDERR.puts text[-6000..] if text.size > 0
        end
      end
      1
    ensure
      processes.reverse_each { |process| Checks.stop(process) }
      stop_signals.each(&.close)
      servers.each(&.close)
      finished.each do |done|
        select
        when done.receive
        when timeout(2.seconds)
        end
      end
      logs.each(&.close)
      FileUtils.rm_rf(runtime) if Dir.exists?(runtime)
      FileUtils.rm_rf(root)
    end
  end
end

exit Caramel::Checks::LatteNetwork.main
