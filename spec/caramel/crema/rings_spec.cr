require "spec"
require "file_utils"
require "../../../src/caramel"

private def report_for(klass : String,
                       line : Int32,
                       message : String = "boom") : Caramel::Crema::ErrorReport
  fingerprint = "#{klass}-#{line}".rjust(12, '0')[0, 12]
  Caramel::Crema::ErrorReport.new(klass, message, [] of String, fingerprint, "app/x.cr:#{line}",
    false, nil, nil, nil, Time.utc, [] of String)
end

describe Caramel::Crema::ErrorRing do
  it "keeps one entry per fingerprint with its count and newest report" do
    ring = Caramel::Crema::ErrorRing.new
    ring.reported(report_for("KeyError", 1, "first"))
    ring.reported(report_for("KeyError", 1, "second"))
    ring.entries.size.should eq(1)
    entry = ring.entries.first
    entry.count.should eq(2)
    entry.report.message.should eq("second")
  end

  it "evicts the entry seen longest ago past 500 fingerprints" do
    ring = Caramel::Crema::ErrorRing.new
    500.times { |index| ring.reported(report_for("E#{index}", index)) }
    first = ring.entries.last.fingerprint
    ring.reported(report_for("Extra", 9999))
    ring.entries.size.should eq(500)
    ring.find(first).should be_nil
  end
end

describe Caramel::Crema::TraceRing do
  it "keeps a slow trace with its spans and drops a fast ok one" do
    ring = Caramel::Crema::TraceRing.new
    Caramel::Crema.subscribe(ring)
    previous = Caramel::Crema.slow_request
    Caramel::Crema.slow_request = 5.milliseconds
    begin
      slow = HTTP::Request.new("GET", "/slow")
      Caramel::Crema.request(slow) do
        sql = Caramel::Crema::SpanKind::Sql
        Caramel::Crema.measure(sql, "SELECT books", "SELECT 1") { sleep 10.milliseconds }
        Caramel::Response.new(body: "slow")
      end
      fast = HTTP::Request.new("GET", "/fast")
      Caramel::Crema.request(fast) { Caramel::Response.new(body: "fast") }
    ensure
      Caramel::Crema.slow_request = previous
      Caramel::Crema.unsubscribe(ring)
    end
    kept = ring.traces
    kept.size.should eq(1)
    kept.first.reason.should eq("slow")
    kept.first.spans.map(&.name).should eq(["SELECT books"])
    ring.traces("error").should be_empty
  end

  it "keeps a failing trace, found by a prefix of its trace id" do
    ring = Caramel::Crema::TraceRing.new
    Caramel::Crema.subscribe(ring)
    begin
      Caramel::Crema.request(HTTP::Request.new("GET", "/broken")) do
        Caramel::Crema.report(KeyError.new("detail"), handled: false)
        Caramel::Response.new(500, "failed")
      end
    ensure
      Caramel::Crema.unsubscribe(ring)
    end
    event = ring.traces.first
    event.reason.should eq("error")
    ring.find(event.trace_id[0, 8]).should eq(event)
    ring.find(event.trace_id[0, 3]).should be_nil
    event.to_json.should_not contain("detail")
  end
end
