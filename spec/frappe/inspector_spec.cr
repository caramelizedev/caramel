require "spec"
require "file_utils"
require "./support/events"
require "../../src/frappe/dev_gateway"

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

# The session cookie the gateway sets on any page.
private def session_cookie(gateway : Caramel::Frappe::DevGateway) : String
  gateway.failed("x")
  gateway.handle(HTTP::Request.new("GET", "/", HOST)).headers["Set-Cookie"].split(';').first
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
    page = gateway.handle(HTTP::Request.new("GET", "/__caramel/dev/inspector/traces/111111", HOST))
    page.status.should eq(200)
    page.body.should contain("zed://file/proj/app/books.cr:12:7")
    page.body.should contain("Copy as Markdown")
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "answers 404 for a trace it does not hold and lists requests on the index" do
    root = "/private/tmp/caramel-inspector-#{Random::Secure.hex(6)}"
    gateway = inspected(root)
    nothing = "/__caramel/dev/inspector/traces/nothing"
    missing = gateway.handle(HTTP::Request.new("GET", nothing, HOST))
    missing.status.should eq(404)
    index = gateway.handle(HTTP::Request.new("GET", "/__caramel/dev/inspector", HOST))
    index.body.should contain("GET /books/:id")
    index.body.should contain("/__caramel/dev/client.js")
  ensure
    FileUtils.rm_rf(root) if root
  end
end
