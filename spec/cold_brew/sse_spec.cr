require "spec"
require "../../src/caramel/sse"

private class FlushCountingIO < IO::Memory
  getter flushes = 0

  def flush
    @flushes += 1
    super
  end
end

private def event(data : String, event : String? = nil) : String
  io = IO::Memory.new
  Caramel::SSE.write(io, event: event, data: data)
  io.to_s
end

describe Caramel::SSE do
  it "writes one data field per line so the browser receives the payload unchanged" do
    event("a\nb", event: "BoardUpdated").should eq("event: BoardUpdated\ndata: a\ndata: b\n\n")
    event("a\r\nb\rc").should eq("data: a\ndata: b\ndata: c\n\n")
    event("ends with newline\n").should eq("data: ends with newline\ndata: \n\n")
    event("").should eq("data: \n\n")
  end

  it "flushes after each event" do
    io = FlushCountingIO.new
    Caramel::SSE.write(io, event: "Tick", data: "1")
    Caramel::SSE.write(io, data: "2")
    io.flushes.should eq(2)
    io.to_s.should eq("event: Tick\ndata: 1\n\ndata: 2\n\n")
  end

  it "refuses an event name that would end the field early" do
    expect_raises(ArgumentError, "line breaks") { event("x", event: "Board\nUpdated") }
    expect_raises(ArgumentError, "line breaks") { event("x", event: "Board\rUpdated") }
  end
end
