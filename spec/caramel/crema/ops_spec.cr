require "spec"
require "file_utils"
require "../../../src/caramel"

private def private_directory : String
  directory = "/private/tmp/caramel-ops-#{Random::Secure.hex(6)}"
  Dir.mkdir(directory, 0o700)
  directory
end

# Runs the block with an ops socket on a fake runtime.
private def with_ops(role : String = "serve", &)
  directory = private_directory
  path = File.join(directory, "ops.sock")
  runtime = Caramel::Crema::Runtime.new(role, "Bookshelf")
  env = {"CARAMEL_OPS_SOCKET" => path}
  stopper = Caramel::Crema::Ops.start(runtime, env) || fail("no ops socket")
  begin
    yield path, runtime
  ensure
    stopper.call
    FileUtils.rm_rf(directory)
  end
end

private def ops(path : String,
                method : String,
                target : String,
                headers : Hash(String, String) = {} of String => String,
                body : String? = nil) : HTTP::Client::Response
  client = HTTP::Client.new(UNIXSocket.new(path), "ops")
  sent = HTTP::Headers{"Host" => "ops"}
  headers.each { |name, value| sent[name] = value }
  client.exec(method, target, sent, body)
ensure
  client.try(&.close)
end

describe Caramel::Crema::Ops do
  it "answers /v1/status with the process facts" do
    with_ops do |path, _|
      response = ops(path, "GET", "/v1/status")
      response.status_code.should eq(200)
      status = JSON.parse(response.body)
      %w[version app caramel role pid started_at uptime_s environment inflight fibers gc pools
        workers scheduler sinks dropped].each do |key|
        status[key]?.should_not be_nil
      end
      status["app"].as_s.should eq("Bookshelf")
      status["sinks"].as_a.map(&.as_s).should contain("errors")
    end
  end

  it "binds a socket only its owner can use" do
    with_ops do |path, _|
      File.info(path).permissions.value.should eq(0o600)
    end
  end

  it "refuses an unknown Host with 421" do
    with_ops do |path, _|
      ops(path, "GET", "/v1/status", {"Host" => "evil.example"}).status_code.should eq(421)
      ops(path, "GET", "/v1/status", {"Host" => "localhost:8765"}).status_code.should eq(200)
    end
  end

  it "refuses a write that carries an Origin header" do
    with_ops do |path, _|
      headers = {"Content-Type" => "application/json", "Origin" => "https://evil.example"}
      response = ops(path, "POST", "/v1/debug-tokens", headers, %({"minutes":5}))
      response.status_code.should eq(403)
      JSON.parse(response.body)["error"]["code"].as_s.should eq("forbidden")
    end
  end

  it "serves Prometheus text with the exposition content type" do
    with_ops do |path, _|
      served = Caramel::Crema.request(HTTP::Request.new("GET", "/books/1")) do
        Caramel::Crema.routed("GET", "/books/:id", "Books::Show")
        Caramel::Response.new(body: "ok")
      end
      served.status.should eq(200)
      response = ops(path, "GET", "/v1/metrics")
      response.headers["Content-Type"].should eq("text/plain; version=0.0.4; charset=utf-8")
      expected = %(caramel_requests_total{method="GET",route="/books/:id",status="200"})
      response.body.should contain(expected)
    end
  end

  it "issues a debug token to the owner and refuses one with the wrong shape" do
    Caramel::Crema.debug_key = Bytes.new(32, 7_u8)
    with_ops do |path, _|
      json = {"Content-Type" => "application/json"}
      issued = ops(path, "POST", "/v1/debug-tokens", json, %({"minutes":30}))
      issued.status_code.should eq(200)
      token = JSON.parse(issued.body)["token"].as_s
      Caramel::Crema::DebugToken.valid?(Bytes.new(32, 7_u8), token).should be_true
      ops(path, "POST", "/v1/debug-tokens", json, %({"minutes":500})).status_code.should eq(400)
      ops(path, "POST", "/v1/debug-tokens", {} of String => String, "{}").status_code.should eq(415)
    end
  ensure
    Caramel::Crema.debug_key = nil
  end

  it "answers 404 in the JSON error shape for an unknown API path" do
    with_ops do |path, _|
      response = ops(path, "GET", "/v1/nothing")
      response.status_code.should eq(404)
      JSON.parse(response.body)["error"]["code"].as_s.should eq("not_found")
    end
  end

  it "serves the console's pages with a strict content security policy" do
    with_ops do |path, _|
      page = ops(path, "GET", "/")
      page.status_code.should eq(200)
      page.body.should contain("<title>Overview · Crema</title>")
      page.headers["Content-Security-Policy"].should contain("script-src 'self'")
      ops(path, "GET", "/insights").body.should contain("The Crema recorder is off")
    end
  end

  it "gives the console a theme: a head script, a button, variables and the shared trace styles" do
    with_ops do |path, _|
      page = ops(path, "GET", "/").body
      page.partition("</head>")[0].should contain(%(<script src="/theme.js"></script>))
      page.should contain("data-caramel-theme")
      ops(path, "GET", "/theme.js").body.should contain("caramel.dev.theme")
      css = ops(path, "GET", "/console.css").body
      css.should contain(":root[data-theme=dark]")
      css.scan(":root[data-theme=dark]").size.should eq(1)
      css.should contain(".bar.view rect")
      css.scan(/var\((--[a-z-]+)\)/).each { |match| css.should contain("#{match[1]}:") }
      ops(path, "GET", "/console.js").body.should contain("data-caramel-theme")
    end
  end

  it "has no ops socket in a work process unless one is asked for" do
    runtime = Caramel::Crema::Runtime.new("work", "Bookshelf")
    Caramel::Crema::Ops.path_for(runtime, {"CARAMEL_SOCKET" => "/tmp/app.sock"}).should be_nil
    explicit = {"CARAMEL_OPS_SOCKET" => "/tmp/work.sock"}
    Caramel::Crema::Ops.path_for(runtime, explicit).should eq("/tmp/work.sock")
  end

  it "derives the serve path from the application socket, and honors off" do
    from_socket = {"CARAMEL_SOCKET" => "/run/app/bookshelf.sock"}
    Caramel::Crema::Ops.path(from_socket).should eq("/run/app/bookshelf.ops.sock")
    Caramel::Crema::Ops.path(from_socket.merge({"CARAMEL_OPS_SOCKET" => "off"})).should be_nil
    Caramel::Crema::Ops.path({} of String => String).should be_nil
  end

  it "answers 413 to a debug-token body over 1 KiB and 400 to a bad minutes value" do
    Caramel::Crema.debug_key = Bytes.new(32, 7_u8)
    with_ops do |path, _|
      json = {"Content-Type" => "application/json"}
      big = %({"minutes":5,"pad":"#{"x" * 2000}"})
      response = ops(path, "POST", "/v1/debug-tokens", json, big)
      response.status_code.should eq(413)
      JSON.parse(response.body)["error"]["code"].as_s.should eq("request_too_large")
      ops(path, "POST", "/v1/debug-tokens", json, %({"minutes":"soon"})).status_code.should eq(400)
      ops(path, "POST", "/v1/debug-tokens", json, "{").status_code.should eq(400)
      ops(path, "POST", "/v1/debug-tokens", json, "{}").status_code.should eq(200)
    end
  ensure
    Caramel::Crema.debug_key = nil
  end

  it "leaves a regular file at the socket path alone and does not bind" do
    directory = private_directory
    path = File.join(directory, "ops.sock")
    File.write(path, "keep me")
    begin
      runtime = Caramel::Crema::Runtime.new("serve", "Bookshelf")
      Caramel::Crema::Ops.start(runtime, {"CARAMEL_OPS_SOCKET" => path}).should be_nil
      File.read(path).should eq("keep me")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe Caramel::Crema::DebugToken do
  key = Bytes.new(32, 3_u8)

  it "accepts a fresh token and refuses an expired, tampered or over-long one" do
    now = Time.utc
    token, _ = Caramel::Crema::DebugToken.issue(key, 15, now)
    Caramel::Crema::DebugToken.valid?(key, token, now).should be_true
    Caramel::Crema::DebugToken.valid?(key, token, now + 16.minutes).should be_false
    Caramel::Crema::DebugToken.valid?(key, token.sub('.', ".0"), now).should be_false
    Caramel::Crema::DebugToken.valid?(Bytes.new(32, 4_u8), token, now).should be_false
    long, _ = Caramel::Crema::DebugToken.issue(key, 180, now)
    Caramel::Crema::DebugToken.valid?(key, long, now).should be_false
  end

  it "makes a request a debug trace, recorded and returned with its trace id" do
    Caramel::Crema.debug_key = key
    token, _ = Caramel::Crema::DebugToken.issue(key, 15)
    headers = HTTP::Headers{"X-Caramel-Debug" => token}
    seen = nil
    response = Caramel::Crema.request(HTTP::Request.new("GET", "/", headers)) do |trace|
      seen = trace
      Caramel::Response.new(body: "ok")
    end
    seen.not_nil!.debug?.should be_true
    seen.not_nil!.recording?.should be_true
    response.headers["X-Caramel-Trace"].should eq(seen.not_nil!.trace_id)
  ensure
    Caramel::Crema.debug_key = nil
  end

  it "leaves a request without a valid token an ordinary trace" do
    Caramel::Crema.debug_key = key
    headers = HTTP::Headers{"X-Caramel-Debug" => "1.forged"}
    response = Caramel::Crema.request(HTTP::Request.new("GET", "/", headers)) do
      Caramel::Response.new(body: "ok")
    end
    response.headers.has_key?("X-Caramel-Trace").should be_false
  ensure
    Caramel::Crema.debug_key = nil
  end
end

describe "The ops socket's error ring" do
  it "serves an error's message only from its own endpoint" do
    with_ops do |path, _|
      subscriber = Caramel::Crema.tail.subscribe(Caramel::Crema::TailSink::Filter.new)
      begin
        report = Caramel::Crema.report(KeyError.new("the secret detail"), handled: false)
        listing = ops(path, "GET", "/v1/errors").body
        listing.should contain(report.fingerprint)
        listing.should_not contain("the secret detail")
        detail = JSON.parse(ops(path, "GET", "/v1/errors/#{report.fingerprint}").body)
        detail["error"]["report"]["message"].as_s.should eq("the secret detail")
        subscriber.channel.receive.should_not contain("the secret detail")
      ensure
        Caramel::Crema.tail.unsubscribe(subscriber)
      end
    end
  end

  it "answers 404 for a fingerprint it never saw, and keeps a failing trace's spans" do
    with_ops do |path, _|
      ops(path, "GET", "/v1/errors/0123456789ab").status_code.should eq(404)
      Caramel::Crema.request(HTTP::Request.new("GET", "/broken")) do
        Caramel::Crema.measure(Caramel::Crema::SpanKind::Sql, "SELECT 1", "SELECT 1") { }
        Caramel::Crema.report(RuntimeError.new("x"), handled: false)
        Caramel::Response.new(500, "failed")
      end
      traces = JSON.parse(ops(path, "GET", "/v1/traces?reason=error").body)["traces"].as_a
      traces.first["spans"].as_a.first["name"].as_s.should eq("SELECT 1")
      id = traces.first["trace_id"].as_s
      ops(path, "GET", "/v1/traces/#{id[0, 8]}").status_code.should eq(200)
      ops(path, "GET", "/v1/traces/#{id[0, 3]}").status_code.should eq(404)
    end
  end
end

describe Caramel::Crema::OpsClient do
  # Exit status of the client against a socket that does not exist: 2 means the arguments
  # were refused as usage, 1 means they were accepted and only the socket was missing.
  exit_status = ->(arguments : Array(String)) do
    socket = "--socket=/private/tmp/caramel-no-such-ops.sock"
    Caramel::Crema::OpsClient.new(arguments + [socket], IO::Memory.new, IO::Memory.new).run
  end

  it "refuses a value on a reason flag of traces instead of reading it as no filter" do
    exit_status.call(["traces", "--slow=500"]).should eq(2)
    exit_status.call(["traces", "--errors=1"]).should eq(2)
    exit_status.call(["traces", "--slow"]).should eq(1)
    exit_status.call(["traces", "--debug", "--limit=5"]).should eq(1)
  end

  it "refuses a numeric option given without a number, so tail's bare --slow is not ignored" do
    exit_status.call(["tail", "--slow"]).should eq(2)
    exit_status.call(["tail", "--slow=abc"]).should eq(2)
    exit_status.call(["traces", "--limit"]).should eq(2)
    exit_status.call(["debug-token", "--minutes"]).should eq(2)
    exit_status.call(["tail", "--slow=500", "--errors"]).should eq(1)
  end
end
