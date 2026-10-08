require "spec"
require "http/client"
require "../../src/latte/collector"

# An OTLP/HTTP JSON export of *spans*, each `{service, trace, span, parent}`.
private def export(*spans : {String, String, String, String?}) : String
  grouped = spans.to_a.group_by(&.[0])
  resources = grouped.map do |service, items|
    attribute = {key: "service.name", value: {stringValue: service}}
    listed = items.map do |_, trace, span, parent|
      {
        traceId: trace, spanId: span, parentSpanId: parent || "", name: "GET /#{service}", kind: 2,
        startTimeUnixNano: "1790000000000000000", endTimeUnixNano: "1790000000042000000",
        status: {code: service == "billing" ? 2 : 1},
        attributes: [{key: "http.status_code", value: {intValue: "500"}}],
      }
    end
    {resource: {attributes: [attribute]}, scopeSpans: [{spans: listed}]}
  end
  {resourceSpans: resources}.to_json
end

private def free_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  server.local_address.port.tap { server.close }
end

private TRACE = "0123456789abcdef0123456789abcdef"

describe Caramel::Latte::Collector do
  it "takes its port from CARAMEL_LATTE_OTLP_PORT, or 4318" do
    Caramel::Latte::Collector.port(nil).should eq 4318
    Caramel::Latte::Collector.port("4319").should eq 4319
    Caramel::Latte::Collector.port("65535").should eq 65535
    ["0", "65536", "otlp"].each do |value|
      expect_raises(Caramel::Latte::PublicError,
        "CARAMEL_LATTE_OTLP_PORT must be a port from 1 to 65535") do
        Caramel::Latte::Collector.port(value)
      end
    end
  end

  it "stores two services under one trace id and lists them together" do
    collector = Caramel::Latte::Collector.new(0)
    collector.ingest(export({"bookshelf", TRACE, "aaaaaaaaaaaaaaaa", nil}))
    collector.ingest(export({"billing", TRACE, "bbbbbbbbbbbbbbbb", "aaaaaaaaaaaaaaaa"}))
    listed = collector.traces
    listed.size.should eq(1)
    listed[0].services.should eq(%w[billing bookshelf])
    listed[0].span_count.should eq(2)
    listed[0].error.should be_true
    listed[0].name.should eq("GET /bookshelf")
    listed[0].duration_ms.should eq(42.0)
    spans = collector.spans(TRACE).not_nil!
    spans.map(&.service).should eq(%w[bookshelf billing])
    spans[1].parent_id.should eq("aaaaaaaaaaaaaaaa")
    spans[0].parent_id.should be_nil
    spans[1].error?.should be_true
    spans[1].attributes.should eq({"http.status_code" => "500"})
  end

  it "evicts the oldest trace past 2 000" do
    collector = Caramel::Latte::Collector.new(0)
    (0..Caramel::Latte::Collector::MAX_TRACES).each do |index|
      trace = index.to_s(16).rjust(32, '0')
      collector.ingest(export({"bookshelf", trace, "aaaaaaaaaaaaaaaa", nil}))
    end
    collector.spans("0" * 32).should be_nil
    collector.spans("0" * 31 + "1").should_not be_nil
    collector.traces(10_000).size.should eq(Caramel::Latte::Collector::MAX_TRACES)
  end

  it "drops and counts spans past 200 in one trace" do
    collector = Caramel::Latte::Collector.new(0)
    (Caramel::Latte::Collector::MAX_SPANS + 3).times do |index|
      span = index.to_s(16).rjust(16, '0')
      collector.ingest(export({"bookshelf", TRACE, span, nil}))
    end
    collector.spans(TRACE).not_nil!.size.should eq(Caramel::Latte::Collector::MAX_SPANS)
    collector.dropped.should eq(3)
  end

  it "ignores spans with a malformed trace id" do
    collector = Caramel::Latte::Collector.new(0)
    collector.ingest(export({"bookshelf", "short", "aaaaaaaaaaaaaaaa", nil}))
    collector.traces.should be_empty
  end

  it "ignores documents that are not OTLP objects" do
    collector = Caramel::Latte::Collector.new(0)
    ["[]", "42", "null"].each do |body|
      expect_raises(JSON::ParseException) { collector.ingest(body) }
    end
    [%({"resourceSpans":[1]}), %({"resourceSpans":[{"scopeSpans":[2]}]})]
      .each { |body| collector.ingest(body) }
    collector.traces.should be_empty
  end

  it "clamps kinds, drops bad timestamps and ids, and truncates names" do
    collector = Caramel::Latte::Collector.new(0)
    span = ->(id : String, kind : String, start : String, name : String) do
      %({"traceId":"#{TRACE}","spanId":"#{id}","kind":#{kind},"name":"#{name}",) +
      %("startTimeUnixNano":"#{start}","endTimeUnixNano":"5"})
    end
    spans = [
      span.call("aaaaaaaaaaaaaaaa", "999999", "1790000000000000000", "x" * 600),
      span.call("bbbbbbbbbbbbbbbb", "2", "-5", "negative"),
      span.call("not-a-span-id", "2", "1790000000000000000", "badid"),
    ]
    collector.ingest(%({"resourceSpans":[{"scopeSpans":[{"spans":[#{spans.join(',')}]}]}]}))
    stored = collector.spans(TRACE).not_nil!
    stored.size.should eq(1)
    stored[0].kind.should eq(0)
    stored[0].name.bytesize.should eq(256)
    stored[0].end_unix_nano.should eq(stored[0].start_unix_nano)
  end

  it "answers OTLP over loopback HTTP and refuses what it does not accept" do
    port = free_port
    collector = Caramel::Latte::Collector.new(port)
    collector.start
    begin
      collector.state.should eq("running")
      json = HTTP::Headers{"Content-Type" => "application/json"}
      url = "http://127.0.0.1:#{port}/v1/traces"
      accepted = HTTP::Client.post(url, json, export({"billing", TRACE, "bbbbbbbbbbbbbbbb", nil}))
      {accepted.status_code, accepted.body}.should eq({200, "{}"})
      accepted.headers["Connection"].should eq("close")
      collector.spans(TRACE).not_nil!.size.should eq(1)

      protobuf = HTTP::Headers{"Content-Type" => "application/x-protobuf"}
      refused = HTTP::Client.post(url, protobuf, "\x0a\x00")
      refused.status_code.should eq(415)
      refused.body.should contain("OTEL_EXPORTER_OTLP_PROTOCOL=http/json")

      huge = " " * (Caramel::Latte::Collector::MAX_BODY + 1)
      HTTP::Client.post(url, json, huge).status_code.should eq(413)
      HTTP::Client.post(url, json, "{not json").status_code.should eq(400)
      ["[]", "42", %("text")].each do |body|
        HTTP::Client.post(url, json, body).status_code.should eq(400)
      end
      HTTP::Client.get(url).status_code.should eq(404)
      metrics = "http://127.0.0.1:#{port}/v1/metrics"
      HTTP::Client.post(metrics, json, "{}").status_code.should eq(404)
    ensure
      collector.stop
    end
  end

  it "stays unavailable, not crashed, when its port is in use" do
    holder = TCPServer.new("127.0.0.1", 0)
    begin
      collector = Caramel::Latte::Collector.new(holder.local_address.port)
      collector.start
      collector.state.should eq("unavailable")
      collector.error.should eq("port #{holder.local_address.port} is in use")
    ensure
      holder.close
    end
  end
end
