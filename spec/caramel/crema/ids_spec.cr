require "spec"
require "../../../src/caramel/crema"

describe Caramel::Crema::Ids do
  trace_id = "0af7651916cd43dd8448eb211c80319c"
  parent_id = "b7ad6b7169203331"

  it "reads a valid traceparent with its sampled bit" do
    parsed = Caramel::Crema::Ids.parse_traceparent("00-#{trace_id}-#{parent_id}-01")
    parsed.should eq({trace_id, parent_id, true})
    unsampled = Caramel::Crema::Ids.parse_traceparent("00-#{trace_id}-#{parent_id}-00")
    unsampled.should eq({trace_id, parent_id, false})
  end

  it "refuses another version, uppercase hex and all-zero ids" do
    refused = [
      "01-#{trace_id}-#{parent_id}-01",
      "00-#{trace_id.upcase}-#{parent_id}-01",
      "00-#{"0" * 32}-#{parent_id}-01",
      "00-#{trace_id}-#{"0" * 16}-01",
    ]
    refused.each { |header| Caramel::Crema::Ids.parse_traceparent(header).should be_nil }
  end

  it "formats an outbound traceparent" do
    header = Caramel::Crema::Ids.traceparent(trace_id, parent_id, false)
    header.should eq("00-#{trace_id}-#{parent_id}-00")
  end

  it "generates a trace id of 32 hex digits and a span id of 16" do
    trace, span = Caramel::Crema::Ids.generate
    trace.should match(/\A[0-9a-f]{32}\z/)
    span.should match(/\A[0-9a-f]{16}\z/)
  end
end
