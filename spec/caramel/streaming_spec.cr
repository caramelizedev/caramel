require "spec"
require "../../src/caramel"

STREAM_GATE = Channel(Nil).new

abstract struct StreamingSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

struct StreamingSpecEvents < StreamingSpecAction
  contract do
  end

  def handle(contract : Contract)
    stream("text/event-stream") { |io| io << "data: one\n\n"; io.flush; STREAM_GATE.receive; io << "data: two\n\n" }
  end
end

module StreamingSpecApp
  Caramel::Router.draw do
    get "/events", StreamingSpecEvents
  end
end

private def streaming_spec_app : Caramel::Application
  Caramel::Application.new(StreamingSpecApp::AppRouter.new, Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel"))
end

private def streaming_spec_line(io : IO) : String?
  line = Channel(String?).new(1)
  spawn { line.send(io.gets) }
  select
  when value = line.receive
    value
  when timeout(2.seconds)
    fail "timed out waiting for a streamed event"
  end
end

describe "Caramel streaming responses" do
  it "writes each event to the client before the stream finishes" do
    server = HTTP::Server.new([streaming_spec_app] of HTTP::Handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn server.listen
    begin
      HTTP::Client.new(address.address, address.port) do |client|
        client.get("/events", HTTP::Headers{"Host" => "bookshelf.caramel"}) do |response|
          response.headers["Content-Type"].should eq("text/event-stream")
          streaming_spec_line(response.body_io).should eq("data: one")
          STREAM_GATE.send(nil)
          streaming_spec_line(response.body_io).should eq("")
          streaming_spec_line(response.body_io).should eq("data: two")
        end
      end
    ensure
      server.close
    end
  end

  it "answers HEAD without running the stream or claiming a length" do
    response = streaming_spec_app.handle(HTTP::Request.new("HEAD", "/events", HTTP::Headers{"Host" => "bookshelf.caramel"}))
    response.status.should eq(200)
    response.body.should eq("")
    response.streamer.should be_nil
    response.headers.has_key?("Content-Length").should be_false
  end
end
