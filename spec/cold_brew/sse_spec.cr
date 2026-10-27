require "spec"
require "../../src/caramel/sse"

private class FlushCountingIO < IO::Memory
  getter flushes = 0

  def flush
    @flushes += 1
    super
  end
end

# Signals each flush, so an example can wait for the heartbeat before it sends.
private class FlushSignallingIO < IO::Memory
  getter flushed = Channel(Nil).new(8)

  def flush
    super
    @flushed.send(nil)
  end
end

# A client connection the browser has already closed.
private class ClosedIO < IO
  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("Broken pipe")
  end
end

private def await(signal : Channel(Nil), what : String) : Nil
  select
  when signal.receive
  when timeout(2.seconds)
    fail "timed out waiting for #{what}"
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

  it "writes a comment as one line the browser ignores, and flushes it" do
    io = FlushCountingIO.new
    Caramel::SSE.comment(io, "ping")
    Caramel::SSE.comment(io)
    io.flushes.should eq(2)
    io.to_s.should eq(": ping\n\n: \n\n")
    expect_raises(ArgumentError, "line breaks") { Caramel::SSE.comment(io, "a\nb") }
  end

  it "relays a heartbeat after a silent interval, then the next event, until the channel closes" do
    io = FlushSignallingIO.new
    updates = Channel(String).new
    done = Channel(Nil).new
    spawn do
      Caramel::SSE.relay(io, updates, event: "Tick", heartbeat: 50.milliseconds)
      done.send(nil)
    end
    await(io.flushed, "the heartbeat")
    io.to_s.should eq(": ping\n\n")
    updates.send("1")
    await(io.flushed, "the event")
    updates.close
    io.to_s.should eq(": ping\n\nevent: Tick\ndata: 1\n\n")
    await(done, "relay to return")
  end

  it "relays a closed channel as a normal end, without an event" do
    io = FlushCountingIO.new
    Caramel::SSE.relay(io, Channel(String).new.tap(&.close))
    io.to_s.should eq("")
  end

  it "fails the relay at the heartbeat when the client has dropped" do
    expect_raises(IO::Error, "Broken pipe") do
      Caramel::SSE.relay(ClosedIO.new, Channel(String).new, heartbeat: 10.milliseconds)
    end
  end
end
