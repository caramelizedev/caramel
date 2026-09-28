require "./support/unix_http"

module Caramel::Checks::LatteIPC
  extend self

  private def run!(command : Array(String), timeout : Time::Span) : Caramel::Latte::ProcessResult
    result = Checks.run(command, timeout: timeout)
    raise result.stdout + result.stderr unless result.success?
    result
  end

  def main : Int32
    root = Checks.private_temp("latte-ipc-")
    runtime = Checks.runtime_root(root)
    socket = File.join(runtime, "latte.sock")
    child : Process? = nil
    begin
      run!([File.join(Checks::REPO, "scripts/crystal"), "build", "spec/fixtures/latte_ipc.cr", "-o", File.join(root, "ipc")], 60.seconds)
      run!([File.join(Checks::REPO, "scripts/build-latte-menu")], 60.seconds)
      File.open(File.join(root, "server.log"), "a", 0o600) do |log|
        child = Process.new([File.join(root, "ipc"), root], chdir: Checks::REPO, output: log, error: log, input: Process::Redirect::Close)
      end
      deadline = Time.instant + 5.seconds
      until File.exists?(socket)
        raise File.read(File.join(root, "server.log")) if child.not_nil!.terminated?
        raise "Latte IPC socket did not become ready" if Time.instant >= deadline
        sleep 50.milliseconds
      end
      raise "Latte IPC socket is not private" unless File.info(socket).permissions.value & 0o777 == 0o600
      menu = Checks.run([File.join(Checks::REPO, "bin/Latte.app/Contents/MacOS/Latte"), "--check"], env: {"CARAMEL_HOME" => root}, timeout: 10.seconds)
      raise menu.stdout + menu.stderr unless menu.success?
      raise menu.stdout unless menu.stdout.includes?("https://bookshelf.caramel")
      response = run!(["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "3", "--unix-socket", socket,
                       "-H", "Content-Type: application/json", "--data", "{}", "http://localhost/v1/services/start"], 30.seconds)
      raise response.stdout unless JSON.parse(response.stdout)["version"].as_i == 1
      body = {name: "expired", directory: root}.to_json
      slow = UNIXSocket.new(socket)
      begin
        slow.read_timeout = 5.seconds
        slow.write_timeout = 5.seconds
        slow << "POST /v1/sites HTTP/1.1\r\n"
        4.times do |index|
          sleep 3.1.seconds
          slow << "X-Trickle-#{index}: 1\r\n"
        end
        slow << "Content-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        expired = Bytes.new(65536)
        count = slow.read(expired)
        raise String.new(expired[0, count]) unless String.new(expired[0, count]).split("\r\n", 2).first.includes?("503")
      ensure
        slow.close
      end
      sites = run!(["/usr/bin/curl", "--silent", "--show-error", "--fail", "--max-time", "3", "--unix-socket", socket, "http://localhost/v1/sites"], 30.seconds)
      names = JSON.parse(sites.stdout)["sites"].as_a.map(&.["name"].as_s)
      raise sites.stdout unless names == ["bookshelf"]
      puts "Native Swift client + real owner-only Crystal IPC + service command + expired trickled request: passed"
      0
    rescue ex
      STDERR.puts ex.message
      1
    ensure
      Checks.stop(child) if child
      FileUtils.rm_rf(runtime) if Dir.exists?(runtime)
      FileUtils.rm_rf(root)
    end
  end
end

exit Caramel::Checks::LatteIPC.main
