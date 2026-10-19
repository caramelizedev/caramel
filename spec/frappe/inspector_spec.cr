require "spec"
require "file_utils"
require "./support/events"
require "http/server"
require "../../src/frappe/dev_gateway"
require "../../src/frappe/latte_client"

private HOST = HTTP::Headers{"Host" => "bookshelf.caramel"}

# A gateway whose inspector holds one trace with a query that came from app/books.cr.
private def inspected(root : String) : Caramel::Frappe::DevGateway
  logs = File.join(root, "logs")
  Dir.mkdir_p(logs)
  trace = EventFixtures.trace("GET /books/:id", "1" * 32)
  trace.spans = [EventFixtures.query("SELECT 1", "app/books.cr:12:7")]
  File.write(File.join(logs, "events.jsonl"), EventFixtures.line(trace) + "\n", perm: 0o600)
  events = Caramel::Frappe::DevEvents.new(root, logs, IO::Memory.new)
  editor = Caramel::Crema::Editor.from(nil)
  origin = "https://bookshelf.caramel"
  gateway = Caramel::Frappe::DevGateway.new(origin, [] of String, editor, "/proj")
  gateway.events = events
  gateway
end

# The session cookie that a single-use sign-in link sets.
private def session_cookie(gateway : Caramel::Frappe::DevGateway) : String
  signed = gateway.handle(HTTP::Request.new("GET", gateway.sign_in_path, HOST))
  signed.headers["Set-Cookie"].split(';').first
end

# A GET of *path* from a browser that signed in with the single-use link.
private def signed_get(gateway : Caramel::Frappe::DevGateway, path : String) : Caramel::Response
  headers = HOST.dup
  headers["Cookie"] = session_cookie(gateway)
  gateway.handle(HTTP::Request.new("GET", path, headers))
end

describe Caramel::Frappe::Inspector do
  it "refuses the traces feed without the development session" do
    root = "/private/tmp/caramel-inspector-#{Random::Secure.hex(6)}"
    gateway = inspected(root)
    feed = "/__caramel/dev/traces.json"
    gateway.handle(HTTP::Request.new("GET", feed, HOST)).status.should eq(403)
    headers = HOST.dup
    headers["Cookie"] = session_cookie(gateway)
    headers["X-Caramel-Dev"] = "1"
    response = gateway.handle(HTTP::Request.new("GET", feed, headers))
    response.status.should eq(200)
    traces = JSON.parse(response.body)["traces"].as_a
    traces.map(&.["name"].as_s).should eq(["GET /books/:id"])
    own = gateway.handle(HTTP::Request.new("GET", "#{feed}?request=req-11111111", headers))
    json = JSON.parse(own.body)
    json["traces"].as_a.size.should eq(1)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "links a query's source to the editor on the trace page" do
    root = "/private/tmp/caramel-inspector-#{Random::Secure.hex(6)}"
    gateway = inspected(root)
    page = signed_get(gateway, "/__caramel/dev/inspector/traces/111111")
    page.status.should eq(200)
    page.body.should contain("zed://file/proj/app/books.cr:12:7")
    page.body.should contain("Copy as Markdown")
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "offers a colour theme: a blocking script in the head, a button, and the stored choice" do
    root = "/private/tmp/caramel-inspector-#{Random::Secure.hex(6)}"
    gateway = inspected(root)
    page = signed_get(gateway, "/__caramel/dev/inspector")
    head = page.body.partition("</head>")[0]
    head.should contain(%(<script src="/__caramel/dev/theme.js"></script>))
    head.should contain(%(<meta name="color-scheme" content="light dark">))
    page.body.should contain("data-caramel-theme")
    script = gateway.handle(HTTP::Request.new("GET", "/__caramel/dev/theme.js", HOST))
    script.status.should eq(200)
    script.headers["Content-Type"].should start_with("text/javascript")
    script.body.should contain("caramel.dev.theme")
    css = gateway.handle(HTTP::Request.new("GET", "/__caramel/dev/inspector.css", HOST)).body
    css.should contain(":root[data-theme=dark]")
    css.should contain("prefers-color-scheme:dark")
    css.scan(":root[data-theme=dark]").size.should eq(1)
    css.should contain(".bar.view rect")
    css.scan(/var\((--[a-z-]+)\)/).each { |match| css.should contain("#{match[1]}:") }
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "serves a trace as Markdown to the toolbar, only inside the development session" do
    root = "/private/tmp/caramel-inspector-#{Random::Secure.hex(6)}"
    gateway = inspected(root)
    address = "/__caramel/dev/trace.md?id=111111"
    gateway.handle(HTTP::Request.new("GET", address, HOST)).status.should eq(403)
    headers = HOST.dup
    headers["Cookie"] = session_cookie(gateway)
    headers["X-Caramel-Dev"] = "1"
    found = gateway.handle(HTTP::Request.new("GET", address, headers))
    found.status.should eq(200)
    found.headers["Content-Type"].should start_with("text/markdown")
    foreign = headers.dup
    foreign["Origin"] = "https://evil.example"
    gateway.handle(HTTP::Request.new("GET", address, foreign)).status.should eq(403)
    bare = HOST.dup
    bare["Cookie"] = session_cookie(gateway)
    gateway.handle(HTTP::Request.new("GET", address, bare)).status.should eq(403)
    found.body.should contain("## Queries")
    found.body.should contain("app/books.cr:12:7")
    ["ffffff", "11111", "last", "", "..%2Fx", "ZZZZZZ"].each do |id|
      address = "/__caramel/dev/trace.md?id=#{id}"
      gateway.handle(HTTP::Request.new("GET", address, headers)).status.should eq(404)
    end
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "answers 404 for a trace it does not hold and lists requests on the index" do
    root = "/private/tmp/caramel-inspector-#{Random::Secure.hex(6)}"
    gateway = inspected(root)
    nothing = "/__caramel/dev/inspector/traces/nothing"
    missing = signed_get(gateway, nothing)
    missing.status.should eq(404)
    index = signed_get(gateway, "/__caramel/dev/inspector")
    index.body.should contain("GET /books/:id")
    index.body.should contain("/__caramel/dev/client.js")
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "shows what other services did in the same trace, from Latte's collector" do
    root = "/private/tmp/caramel-inspector-#{Random::Secure.hex(6)}"
    gateway = inspected(root)
    paths = Caramel::Latte::Paths.new(root)
    id = "1" * 32
    billing = {
      service: "billing", span_id: "c" * 16, parent_id: "b" * 16, name: "POST /charges",
      kind: 2, start_unix_nano: 1_790_000_000_000_000_000_i64,
      end_unix_nano: 1_790_000_000_042_000_000_i64, error: true, attributes: {} of String => String,
    }
    stub = HTTP::Server.new do |context|
      context.response.headers["Content-Type"] = "application/json"
      context.response.headers["Connection"] = "close"
      case context.request.path
      when "/v2/traces/#{id}"
        context.response.print({version: 2, trace_id: id, spans: [billing]}.to_json)
      when "/v2/status"
        collector = {state: "running", port: 4318, error: nil}
        context.response.print({version: 2, services: {} of String => String,
                                collector: collector}.to_json)
      else
        context.response.status_code = 404
        missing = {code: "not_found", message: "No such trace"}
        context.response.print({version: 2, error: missing}.to_json)
      end
    end
    begin
      stub.bind_unix(paths.control_socket)
      File.chmod(paths.control_socket, 0o600)
      spawn { stub.listen }
      client = Caramel::Frappe::LatteClient.new(root)
      client.collector_port.should eq(4318)
      client.collected(id).map(&.service).should eq(["billing"])
      client.collected("f" * 32).should be_empty
      client.collected("not a trace id").should be_empty
      gateway.collected = ->(trace : String) do
        Caramel::Crema::Render.across(client.collected(trace), "bookshelf")
      end
      gateway.events = gateway.events
      address = "/__caramel/dev/inspector/traces/111111"
      page = signed_get(gateway, address)
      page.status.should eq(200)
      page.body.should contain("Across services")
      page.body.should contain("billing")
      page.body.should contain("POST /charges")
    ensure
      stub.try(&.close)
      FileUtils.rm_rf(paths.run_dir) if paths
      FileUtils.rm_rf(root)
    end
  end

  it "refuses every inspector page to a browser that has not signed in" do
    root = "/private/tmp/caramel-inspector-#{Random::Secure.hex(6)}"
    gateway = inspected(root)
    inspector = "/__caramel/dev/inspector"
    ["", "/traces/111111", "/errors", "/builds"].each do |page|
      response = gateway.handle(HTTP::Request.new("GET", inspector + page, HOST))
      response.status.should eq(403)
      response.body.should eq(Caramel::Frappe::DevGateway::SIGNED_OUT)
      response.headers["Set-Cookie"]?.should be_nil
      response.body.should_not contain("GET /books/:id")
    end
    other = inspected("#{root}-other")
    stale = HOST.dup
    stale["Cookie"] = session_cookie(other)
    gateway.handle(HTTP::Request.new("GET", inspector, stale)).status.should eq(403)
  ensure
    FileUtils.rm_rf(root) if root
    FileUtils.rm_rf("#{root}-other") if root
  end

  it "gives the inspector pages to the cookie alone, but the JSON endpoints need the header too" do
    root = "/private/tmp/caramel-inspector-#{Random::Secure.hex(6)}"
    gateway = inspected(root)
    signed_get(gateway, "/__caramel/dev/inspector").status.should eq(200)
    signed_get(gateway, "/__caramel/dev/inspector/errors").status.should eq(200)
    signed_get(gateway, "/__caramel/dev/traces.json").status.should eq(403)
    signed_get(gateway, "/__caramel/dev/trace.md?id=111111").status.should eq(403)
  ensure
    FileUtils.rm_rf(root) if root
  end
end
