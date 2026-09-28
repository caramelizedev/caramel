require "spec"
require "../../scripts/checks/support/harness"
require "file_utils"
require "html"
require "random/secure"

RELAY_BINARY = File.join(Caramel::Checks::REPO, "bin/latte-port-relay")
raise "Run scripts/check native" unless File.file?(RELAY_BINARY)

private class RelayByteServer
  getter port : Int32

  def initialize(@initial : String = "", @eof_reply : String = "")
    @listener = TCPServer.new("127.0.0.1", 0)
    @port = @listener.local_address.port
    @connections = [] of TCPSocket
    @closed = false
    spawn do
      loop do
        client = @listener.accept
        @connections << client
        spawn { serve(client) }
      end
    rescue ex : IO::Error
      raise ex unless @closed
    end
  end

  def close : Nil
    @closed = true
    @listener.close
    @connections.each { |client| client.close unless client.closed? }
  end

  protected def serve(client : TCPSocket) : Nil
    client.read_timeout = 2.seconds
    client << @initial unless @initial.empty?
    buffer = Bytes.new(16 * 1024)
    loop do
      count = client.read(buffer)
      if count == 0
        unless @eof_reply.empty?
          client << @eof_reply
          client.close_write
        end
        break
      end
      client.write(buffer[0, count])
    end
  rescue IO::Error
    # Closing a probe or the fixture may interrupt an active connection.
  ensure
    client.close unless client.closed?
  end
end

private class RelayStreamingServer < RelayByteServer
  protected def serve(client : TCPSocket) : Nil
    client.write_timeout = 1.second
    chunk = "stream-byte" * 1489
    loop { client << chunk }
  rescue IO::Error
  ensure
    client.close unless client.closed?
  end
end

private class RelayFixture
  getter http : RelayByteServer
  getter https : RelayByteServer
  getter http_port : Int32
  getter https_port : Int32
  getter relay : Process

  def initialize
    @http = RelayByteServer.new("http-ready", "http-eof")
    @https = RelayByteServer.new("tls-ready", "tls-eof")
    @http_port = Caramel::Checks.free_tcp_port
    @https_port = Caramel::Checks.free_tcp_port
    while @https_port == @http_port
      @https_port = Caramel::Checks.free_tcp_port
    end
    @relay = launch(@http_port, @https_port, @http.port, @https.port)
    @stream = nil
  end

  def restart(target_http : Int32, target_https : Int32, *, stream : RelayStreamingServer? = nil) : Nil
    stop_relay
    @stream = stream
    @http_port = Caramel::Checks.free_tcp_port if stream
    @https_port = Caramel::Checks.free_tcp_port if stream
    while @https_port == @http_port
      @https_port = Caramel::Checks.free_tcp_port
    end
    @relay = launch(@http_port, @https_port, target_http, target_https)
  end

  def connect(port : Int32 = @http_port, timeout : Time::Span = 3.seconds) : TCPSocket
    deadline = Time.instant + timeout
    loop do
      raise "relay exited early with status #{@relay.wait.exit_code}" if @relay.terminated?
      begin
        return TCPSocket.new("127.0.0.1", port, connect_timeout: 0.15)
      rescue Socket::Error | IO::Error
        raise "relay did not accept on 127.0.0.1:#{port}" if Time.instant >= deadline
        sleep 20.milliseconds
      end
    end
  end

  def stop_relay : Nil
    Caramel::Checks.stop(@relay, 3.seconds)
  end

  def close : Nil
    stop_relay
    @http.close
    @https.close
    @stream.try &.close
  end

  private def launch(http_port : Int32, https_port : Int32, target_http : Int32, target_https : Int32) : Process
    Process.new([RELAY_BINARY, "--test-listen", http_port.to_s, https_port.to_s, target_http.to_s, target_https.to_s],
      chdir: Caramel::Checks::REPO, output: Process::Redirect::Close, error: Process::Redirect::Close)
  end
end

def with_relay_fixture(& : RelayFixture ->) : Nil
  fixture = RelayFixture.new
  begin
    yield fixture
  ensure
    fixture.close
  end
end

private class RelayChurn
  getter bytes_received : Int64

  def initialize(@client : TCPSocket, @port : Int32, @relay : Process)
    @stopped = false
    @bytes_received = 0_i64
    @done = Channel(Nil).new(5)
    spawn do
      buffer = Bytes.new(64 * 1024)
      until @stopped
        begin
          size = @client.read(buffer)
          break if size == 0
          @bytes_received += size
        rescue IO::Error
          break
        end
      end
      @done.send(nil)
    end
    4.times do
      spawn do
        until @stopped
          begin
            socket = TCPSocket.new("127.0.0.1", @port, connect_timeout: 0.2)
            begin
              socket.read_timeout = 200.milliseconds
              socket.write_timeout = 200.milliseconds
              socket << "churn"
              answer = Bytes.new(5)
              socket.read_fully(answer)
            ensure
              socket.close
            end
          rescue IO::Error
            break if @relay.terminated?
          end
        end
        @done.send(nil)
      end
    end
  end

  def close : Nil
    @stopped = true
    @client.close
    5.times do
      select
      when @done.receive
      when timeout(2.seconds)
        raise "relay churn worker did not stop"
      end
    end
  end
end

# Runs the relay the way the installed daemon runs: launchd owns the "http"
# and "https" listeners and hands them over through launch_activate_socket.
# A per-user job on unprivileged loopback ports stands in for the system job.
private class LaunchdRelay
  getter http_port : Int32
  getter https_port : Int32
  @domain : String

  def initialize(target_http : Int32, target_https : Int32)
    @directory = Caramel::Checks.private_temp("caramel-relay-launchd-")
    @label = "dev.caramel.ports.check.#{Random::Secure.hex(6)}"
    @log = File.join(@directory, "relay.log")
    @http_port = Caramel::Checks.free_tcp_port
    @https_port = Caramel::Checks.free_tcp_port
    while @https_port == @http_port
      @https_port = Caramel::Checks.free_tcp_port
    end
    plist = File.join(@directory, "#{@label}.plist")
    File.write(plist, plist(target_http, target_https), perm: 0o600)
    @domain = begin
      bootstrap(plist)
    rescue ex
      FileUtils.rm_rf(@directory)
      raise ex
    end
  end

  def log : String
    File.exists?(@log) ? File.read(@log) : ""
  end

  def close : Nil
    Caramel::Checks.run(["/bin/launchctl", "bootout", "#{@domain}/#{@label}"], timeout: 15.seconds)
    FileUtils.rm_rf(@directory)
  end

  # Terminal sessions load per-user jobs into gui/<uid>; sessions without a
  # GUI (for example over SSH) only have user/<uid>.
  private def bootstrap(plist : String) : String
    uid = LibC.getuid
    failures = ["gui/#{uid}", "user/#{uid}"].map do |domain|
      result = Caramel::Checks.run(["/bin/launchctl", "bootstrap", domain, plist], timeout: 15.seconds)
      return domain if result.success?
      "#{domain}: #{result.stderr.strip}"
    end
    raise "launchctl could not load the relay job (#{failures.join("; ")})"
  end

  private def plist(target_http : Int32, target_https : Int32) : String
    arguments = [RELAY_BINARY, "--test-launchd", @http_port.to_s, @https_port.to_s, target_http.to_s, target_https.to_s]
    sockets = {"http" => @http_port, "https" => @https_port}.map do |name, port|
      "<key>#{name}</key><dict><key>SockNodeName</key><string>127.0.0.1</string><key>SockServiceName</key><string>#{port}</string>" \
      "<key>SockFamily</key><string>IPv4</string><key>SockType</key><string>stream</string></dict>"
    end
    <<-PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>Label</key><string>#{@label}</string>
      <key>ProgramArguments</key><array>#{arguments.map { |argument| "<string>#{HTML.escape(argument)}</string>" }.join}</array>
      <key>Sockets</key><dict>#{sockets.join}</dict>
      <key>RunAtLoad</key><true/>
      <key>StandardOutPath</key><string>#{HTML.escape(@log)}</string>
      <key>StandardErrorPath</key><string>#{HTML.escape(@log)}</string>
      </dict></plist>
      PLIST
  end
end

describe "native Latte port relay" do
  it "round trips clear and TLS-like opaque bytes with half-closes" do
    with_relay_fixture do |fixture|
      { {fixture.http_port, "http-ready", "GET /opaque HTTP/1.1\r\n\x16\x03\x01", "http-eof"},
       {fixture.https_port, "tls-ready", "\x16\x03\x03clienthello\x00", "tls-eof"} }.each do |port, ready, payload, eof_reply|
        client = fixture.connect(port)
        begin
          client.read_timeout = 2.seconds
          initial = Bytes.new(ready.bytesize)
          client.read_fully(initial)
          initial.should eq(ready.to_slice)
          client << payload
          echoed = Bytes.new(payload.bytesize)
          client.read_fully(echoed)
          echoed.should eq(payload.to_slice)
          client.close_write
          eof = Bytes.new(eof_reply.bytesize)
          client.read_fully(eof)
          eof.should eq(eof_reply.to_slice)
          client.read_byte.should be_nil
        ensure
          client.close
        end
      end
    end
  end

  it "closes unavailable-target connections but remains running" do
    with_relay_fixture do |fixture|
      unavailable_http = Caramel::Checks.free_tcp_port
      unavailable_https = Caramel::Checks.free_tcp_port
      while unavailable_https == unavailable_http
        unavailable_https = Caramel::Checks.free_tcp_port
      end
      fixture.restart(unavailable_http, unavailable_https)
      fixture.connect.close
      3.times do
        client = fixture.connect
        begin
          client.read_timeout = 2.seconds
          client << "target-unavailable"
          begin
            client.read_byte.should be_nil
          rescue IO::Error
            # A TCP reset is another valid close for a refused destination.
          end
        ensure
          client.close
        end
      end
      fixture.relay.terminated?.should be_false
    end
  end

  it "terminates promptly despite a continuous stream and connection churn" do
    with_relay_fixture do |fixture|
      stream = RelayStreamingServer.new
      fixture.restart(stream.port, fixture.https.port, stream: stream)
      client = fixture.connect
      client.read_timeout = 100.milliseconds
      churn = RelayChurn.new(client, fixture.https_port, fixture.relay)
      begin
        Caramel::Checks.wait_until(1.second, 10.milliseconds) { churn.bytes_received > 256 * 1024 }.should be_true
        started = Time.instant
        fixture.relay.terminate
        Caramel::Checks.wait_until(2.seconds, 10.milliseconds) { fixture.relay.terminated? }.should be_true
        (Time.instant - started).should be < 1.5.seconds
      ensure
        churn.close
      end
    end
  end

  it "releases its listeners on termination" do
    with_relay_fixture do |fixture|
      fixture.connect.close
      fixture.relay.terminate
      Caramel::Checks.wait_until(3.seconds, 10.milliseconds) { fixture.relay.terminated? }.should be_true
      expect_raises(Socket::Error) { TCPSocket.new("127.0.0.1", fixture.http_port, connect_timeout: 0.4) }
    end
  end

  it "serves the listeners launchd hands over, as the installed daemon does" do
    http = RelayByteServer.new("http-ready", "http-eof")
    https = RelayByteServer.new("tls-ready", "tls-eof")
    relay = LaunchdRelay.new(http.port, https.port)
    begin
      { {relay.http_port, "http-ready"}, {relay.https_port, "tls-ready"} }.each do |port, ready|
        client = TCPSocket.new("127.0.0.1", port, connect_timeout: 3.seconds)
        begin
          client.read_timeout = 5.seconds
          initial = Bytes.new(ready.bytesize)
          begin
            client.read_fully(initial)
          rescue ex : IO::Error
            fail "the relay did not serve launchd's listener on 127.0.0.1:#{port} (#{ex.message}); relay output: #{relay.log.inspect}"
          end
          String.new(initial).should eq(ready)
          client << "launchd-payload"
          echoed = Bytes.new("launchd-payload".bytesize)
          client.read_fully(echoed)
          String.new(echoed).should eq("launchd-payload")
        ensure
          client.close
        end
      end
    ensure
      relay.close
      http.close
      https.close
    end
  end
end
