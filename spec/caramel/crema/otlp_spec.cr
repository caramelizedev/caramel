require "spec"
require "../../../src/caramel"
require "../../../src/caramel/crema/otlp"

# A collector on a free port that keeps every body POSTed to it.
private class Collector
  getter bodies = [] of String
  getter paths = [] of String
  getter headers = [] of String?

  def initialize
    @server = HTTP::Server.new do |context|
      @paths << context.request.path
      @headers << context.request.headers["x-api-key"]?
      @bodies << (context.request.body.try(&.gets_to_end) || "")
      context.response.print("{}")
    end
    @address = @server.bind_tcp("127.0.0.1", 0)
    spawn { @server.listen }
  end

  def url : String
    "http://127.0.0.1:#{@address.port}"
  end

  def close : Nil
    @server.close
  end
end

private def exporting(collector : Collector,
                      extra : Hash(String, String) = {} of String => String,
                      &)
  env = {"OTEL_EXPORTER_OTLP_ENDPOINT" => collector.url, "CARAMEL_ENV" => "production"}.merge(extra)
  runtime = Caramel::Crema::Runtime.new("serve", "Bookshelf")
  stopper = Caramel::Crema::Otlp.activate(runtime, env)
  yield stopper
ensure
  stopper.try(&.call)
  collector.close
end

private def spans_of(body : String) : Array(JSON::Any)
  JSON.parse(body)["resourceSpans"][0]["scopeSpans"][0]["spans"].as_a
end

private def attribute(span : JSON::Any, key : String) : String?
  found = span["attributes"].as_a.find { |item| item["key"] == key }
  found.try(&.["value"].as_h.values.first.as_s)
end

describe Caramel::Crema::Otlp do
  it "exports a request as a server span with its route and a client span per query" do
    collector = Collector.new
    exporting(collector) do
      Caramel::Crema.request(HTTP::Request.new("GET", "/books/1")) do
        Caramel::Crema.routed("GET", "/books/:id", "Books::Show")
        sql = Caramel::Crema::SpanKind::Sql
        Caramel::Crema.measure(sql, "SELECT books", "SELECT * FROM books WHERE id = $1") { }
        Caramel::Response.new(body: "ok")
      end
    end
    collector.paths.should eq(["/v1/traces"])
    spans = spans_of(collector.bodies.first)
    root = spans.find! { |span| span["kind"] == 2 }
    attribute(root, "http.route").should eq("/books/:id")
    child = spans.find! { |span| span["kind"] == 3 }
    attribute(child, "db.system.name").should eq("postgresql")
    attribute(child, "db.query.text").should eq("SELECT * FROM books WHERE id = $1")
    child["parentSpanId"].should eq(root["spanId"])
  end

  it "names the service and environment in the resource" do
    collector = Collector.new
    exporting(collector, {"OTEL_SERVICE_NAME" => "bookshelf-web"}) do
      Caramel::Crema.request(HTTP::Request.new("GET", "/")) { Caramel::Response.new(body: "ok") }
    end
    resource = JSON.parse(collector.bodies.first)["resourceSpans"][0]["resource"]["attributes"]
    values = resource.as_a.to_h { |item| {item["key"].as_s, item["value"]["stringValue"].as_s} }
    values["service.name"].should eq("bookshelf-web")
    values["deployment.environment.name"].should eq("production")
    values["telemetry.sdk.name"].should eq("caramel.crema")
  end

  it "exports nothing for an ok trace at ratio 0, and only the root span for an error" do
    collector = Collector.new
    exporting(collector, {"OTEL_TRACES_SAMPLER_ARG" => "0.0"}) do
      fine = HTTP::Request.new("GET", "/fine")
      Caramel::Crema.request(fine) { Caramel::Response.new(body: "ok") }
      Caramel::Crema.request(HTTP::Request.new("GET", "/broken")) do
        sql = Caramel::Crema::SpanKind::Sql
        Caramel::Crema.measure(sql, "SELECT 1", "SELECT 1") { }
        Caramel::Crema.report(KeyError.new("detail"), handled: false)
        Caramel::Response.new(500, "failed")
      end
    end
    spans = collector.bodies.flat_map { |body| spans_of(body) }
    spans.size.should eq(1)
    spans.first["status"]["code"].should eq(2)
    spans.first["events"][0]["attributes"][0]["value"]["stringValue"].should eq("KeyError")
    collector.bodies.join.should_not contain("detail")
  end

  it "sends the configured headers" do
    collector = Collector.new
    exporting(collector, {"OTEL_EXPORTER_OTLP_HEADERS" => "x-api-key=a%20b,other=1"}) do
      Caramel::Crema.request(HTTP::Request.new("GET", "/")) { Caramel::Response.new(body: "ok") }
    end
    collector.headers.should eq(["a b"])
  end

  it "stays off without an endpoint and refuses a protocol it does not speak" do
    runtime = Caramel::Crema::Runtime.new("serve", "Bookshelf")
    Caramel::Crema::Otlp.activate(runtime, {} of String => String).should be_nil
    protobuf = {
      "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://127.0.0.1:1",
      "OTEL_EXPORTER_OTLP_PROTOCOL" => "http/protobuf",
    }
    Caramel::Crema::Otlp.activate(runtime, protobuf).should be_nil
  end

  it "prefers the traces endpoint over the base one" do
    both = {
      "OTEL_EXPORTER_OTLP_ENDPOINT"        => "http://base:4318/",
      "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" => "http://traces:9/custom",
    }
    Caramel::Crema::Otlp.endpoint(both).to_s.should eq("http://traces:9/custom")
    Caramel::Crema::Otlp.endpoint({"OTEL_EXPORTER_OTLP_ENDPOINT" => "http://base:4318/"}).to_s
      .should eq("http://base:4318/v1/traces")
  end

  it "decides a trace id's ratio sample by its first 16 hex digits" do
    request = Caramel::Crema::Kind::Request
    low = Caramel::Crema::Trace.new(request, "GET /", "0" * 15 + "1" + "f" * 16, "b" * 16)
    high = Caramel::Crema::Trace.new(request, "GET /", "f" * 32, "b" * 16)
    sampler = Caramel::Crema::Otlp::Sampler.new("traceidratio", 0.5)
    sampler.sample?(low).should be_true
    sampler.sample?(high).should be_false
  end
end
