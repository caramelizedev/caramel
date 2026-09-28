require "spec"
require "../../scripts/checks/support/harness"

MENU_APP = File.join(Caramel::Checks::REPO, "bin/Latte.app/Contents/MacOS/Latte")
raise "Run scripts/check native" unless File.file?(MENU_APP)

private class FakeMenuDaemon
  def initialize(@path : String, @responses : Hash(String, String), @trickle : Bool = false, @delays : Hash(String, Time::Span) = Hash(String, Time::Span).new)
    @server = UNIXServer.new(@path)
    File.chmod(@path, 0o600)
    @closed = false
    spawn do
      loop do
        client = @server.accept
        spawn { respond(client) }
      end
    rescue ex : IO::Error
      raise ex unless @closed
    end
  end

  def close : Nil
    @closed = true
    @server.close
  end

  private def respond(client : UNIXSocket) : Nil
    client.read_timeout = 5.seconds
    request = client.gets.to_s.split(' ')
    while line = client.gets
      break if line.strip.empty?
    end
    key = "#{request[0]} #{request[1]}"
    body = @responses[key]? || %({"version":1,"error":{"code":"not_found","message":"missing"}})
    status = @responses.has_key?(key) ? "200 OK" : "404 Not Found"
    if delay = @delays[key]?
      sleep delay
    end
    client << "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
    if @trickle
      body.each_byte.with_index do |byte, index|
        if index < 60
          client.write_byte(byte)
          client.flush
          sleep 50.milliseconds
        else
          client << body.byte_slice(index)
          break
        end
      end
    else
      client << body
    end
    client.flush
  rescue IO::Error
    # The client may close on its deadline while the fake daemon is writing.
  ensure
    client.close unless client.closed?
  end
end

private class MenuFixture
  getter home : String
  getter runtime : String

  def initialize
    @temp = Caramel::Checks.private_temp("latte-menu-test-")
    @home = File.join(@temp, "Caramel")
    Dir.mkdir(@home, 0o700)
    Dir.mkdir(File.join(@home, "logs"), 0o700)
    @runtime = Caramel::Latte::StateSecurity.runtime_root(File.realpath(@home))
    Dir.mkdir(@runtime, 0o700)
    @socket = File.join(@runtime, "latte.sock")
    @daemon = nil
  end

  def serve(sites : String = "[]", *, include_sites_version : Bool = true, trickle : Bool = false, delays : Hash(String, Time::Span) = Hash(String, Time::Span).new, postgres : String = "running", dns : String = "running", proxy : String = "stopped", status_error : String? = nil) : Nil
    status = %({"version":1,"services":{"postgres":{"state":#{postgres.to_json},"detail":null},"dns":{"state":#{dns.to_json},"detail":null},"proxy":{"state":#{proxy.to_json},"detail":null}})
    status += %(,"error":#{status_error.to_json}) if status_error
    status += "}"
    sites_response = include_sites_version ? %({"sites":#{sites},"version":1}) : %({"sites":#{sites}})
    @daemon = FakeMenuDaemon.new(@socket, {"GET /v1/status" => status, "GET /v1/sites" => sites_response}, trickle, delays)
  end

  def check : Caramel::Latte::ProcessResult
    Caramel::Checks.run([MENU_APP, "--check"], env: {"CARAMEL_HOME" => @home}, timeout: 10.seconds)
  end

  def close : Nil
    @daemon.try &.close
    FileUtils.rm_rf(@temp)
    File.delete(@socket) if File.exists?(@socket)
    File.chmod(@runtime, 0o700) if Dir.exists?(@runtime)
    Dir.delete(@runtime) if Dir.exists?(@runtime)
  end
end

def with_menu_fixture(& : MenuFixture ->) : Nil
  fixture = MenuFixture.new
  begin
    yield fixture
  ensure
    fixture.close
  end
end

describe "native Latte menu client" do
  it "reads shared status and sites" do
    with_menu_fixture do |fixture|
      site = %([{"id":"0123456789abcdef","name":"bookshelf","directory":#{File.join(fixture.home, "bookshelf").to_json},"suffix":"caramel","domain":"bookshelf.caramel","origin":"https://bookshelf.caramel","upstream":null,"state":"build-error","owner":"terminal"}])
      fixture.serve(sites: site)
      result = fixture.check
      result.success?.should be_true
      result.stdout.should contain("status: postgres=running dns=running proxy=stopped")
      result.stdout.should contain("sites: 1")
      result.stdout.should contain("https://bookshelf.caramel")
      result.stdout.should contain("Build error")
      result.stdout.should contain("Terminal session")
      result.stdout.should contain("logs: #{File.join(fixture.home, "logs/sites/0123456789abcdef")}")
    end
  end

  it "rejects an origin that does not match the validated domain" do
    with_menu_fixture do |fixture|
      fixture.serve(sites: %([{"id":"0123456789abcdef","name":"bookshelf","directory":#{File.join(fixture.home, "bookshelf").to_json},"suffix":"caramel","domain":"bookshelf.caramel","origin":"https://evil.example","upstream":null}]))
      result = fixture.check
      result.success?.should be_false
      (result.stdout + result.stderr).downcase.should contain("origin")
    end
  end

  it "rejects site identifiers that cannot name a log folder" do
    with_menu_fixture do |fixture|
      fixture.serve(sites: %([{"id":"0123456789ABCDEF","name":"bookshelf","directory":#{File.join(fixture.home, "bookshelf").to_json},"suffix":"caramel","domain":"bookshelf.caramel","origin":"https://bookshelf.caramel","upstream":null}]))
      result = fixture.check
      result.success?.should be_false
      (result.stdout + result.stderr).should contain("site identifier")
    end
  end

  it "rejects a runtime directory with non-private mode" do
    with_menu_fixture do |fixture|
      File.chmod(fixture.runtime, 0o755)
      result = fixture.check
      result.success?.should be_false
      (result.stdout + result.stderr).downcase.should contain("private")
    end
  end

  it "rejects sites without a protocol version" do
    with_menu_fixture do |fixture|
      fixture.serve(include_sites_version: false)
      result = fixture.check
      result.success?.should be_false
      (result.stdout + result.stderr).downcase.should contain("json could not be decoded")
    end
  end

  it "accepts a failed service with a status diagnostic" do
    with_menu_fixture do |fixture|
      fixture.serve(postgres: "failed", status_error: "postgres failed to start")
      result = fixture.check
      result.success?.should be_true
      result.stdout.should contain("status: postgres=failed dns=running proxy=stopped")
      result.stdout.should contain("diagnostic: postgres failed to start")
    end
  end

  it "applies one deadline across status and sites requests" do
    with_menu_fixture do |fixture|
      fixture.serve(delays: {"GET /v1/status" => 1.2.seconds, "GET /v1/sites" => 1.2.seconds})
      started = Time.instant
      result = fixture.check
      result.success?.should be_false
      (result.stdout + result.stderr).downcase.should contain("timed out")
      (Time.instant - started).should be < 3.5.seconds
    end
  end

  it "has an aggregate deadline for trickled responses" do
    with_menu_fixture do |fixture|
      fixture.serve(trickle: true)
      started = Time.instant
      result = fixture.check
      result.success?.should be_false
      (result.stdout + result.stderr).downcase.should contain("timed out")
      (Time.instant - started).should be < 6.seconds
    end
  end
end
