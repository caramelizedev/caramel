require "spec"
require "../../src/caramel"

DRAIN_SPEC_HOST = HTTP::Headers{"Host" => "bookshelf.caramel"}

# The gate a request waits on, and where it says it arrived; fresh for each example.
module DrainSpec
  class_property gate = Channel(Nil).new
  class_property entered = Channel(Nil).new(1)

  def self.reset : Nil
    @@gate = Channel(Nil).new
    @@entered = Channel(Nil).new(1)
  end
end

abstract struct DrainSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

# Holds its request until the example opens the gate.
struct DrainSpecHeld < DrainSpecAction
  contract do
  end

  def handle(contract : Contract)
    gate = DrainSpec.gate
    DrainSpec.entered.send(nil)
    gate.receive
    Caramel::Response.new(200, "done")
  end
end

module DrainSpecApp
  Caramel::Router.draw do
    get "/held", DrainSpecHeld
  end
end

private def drain_spec_app : Caramel::Application
  csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
  Caramel::Application.new(DrainSpecApp::AppRouter.new, csrf)
end

# Sends GET /held from a fiber and returns where its response arrives.
private def drain_spec_request(address : Socket::IPAddress) : Channel(HTTP::Client::Response)
  answer = Channel(HTTP::Client::Response).new(1)
  spawn do
    HTTP::Client.new(address.address, address.port) do |client|
      answer.send(client.get("/held", DRAIN_SPEC_HOST))
    end
  end
  answer
end

private def drain_spec_wait(channel : Channel(T)) : T forall T
  select
  when value = channel.receive
    value
  when timeout(2.seconds)
    fail "timed out waiting for the held request"
  end
end

describe "Caramel::Application draining" do
  it "answers an in-flight request with Connection: close and waits for it" do
    DrainSpec.reset
    app = drain_spec_app
    server = HTTP::Server.new([app] of HTTP::Handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn server.listen
    begin
      answer = drain_spec_request(address)
      drain_spec_wait(DrainSpec.entered)
      app.drain
      server.close
      app.wait_idle(100.milliseconds).should eq(1)
      DrainSpec.gate.send(nil)
      response = drain_spec_wait(answer)
      response.headers["Connection"].should eq("close")
      response.body.should eq("done")
      app.wait_idle(2.seconds).should eq(0)
    ensure
      server.close unless server.closed?
    end
  end

  it "gives up after the timeout" do
    DrainSpec.reset
    app = drain_spec_app
    server = HTTP::Server.new([app] of HTTP::Handler)
    address = server.bind_tcp("127.0.0.1", 0)
    spawn server.listen
    begin
      drain_spec_request(address)
      drain_spec_wait(DrainSpec.entered)
      app.drain
      app.wait_idle(50.milliseconds).should eq(1)
    ensure
      select
      when DrainSpec.gate.send(nil)
      when timeout(2.seconds)
      end
      server.close unless server.closed?
    end
  end
end
