require "spec"
require "http/server"
require "../../src/caramel/corretto"

private def with_wire(&)
  wire = Corretto::Wire.new
  previous = Caramel::Outbound.proxy
  Caramel::Outbound.proxy = wire.address
  begin
    yield wire
  ensure
    Caramel::Outbound.proxy = previous
    wire.close
  end
end

describe Corretto::Wire do
  it "parses the absolute-form request bytes an outbound client sends" do
    bytes = "POST https://api.stripe.com/v1/customers?expand=sources HTTP/1.1\r\n" \
            "Host: api.stripe.com\r\n" \
            "Content-Type: application/x-www-form-urlencoded\r\n" \
            "Content-Length: 19\r\n\r\n" \
            "email=a%40acme.test"
    request = Corretto::Wire.read(IO::Memory.new(bytes)).not_nil!
    request.method.should eq("POST")
    request.url.should eq("https://api.stripe.com/v1/customers?expand=sources")
    request.headers["Host"].should eq("api.stripe.com")
    request.body.should eq("email=a%40acme.test")

    chunked = "PUT http://files.example/a.txt HTTP/1.1\r\n" \
              "Host: files.example\r\nTransfer-Encoding: chunked\r\n\r\n" \
              "5\r\nhello\r\n0\r\n\r\n"
    Corretto::Wire.read(IO::Memory.new(chunked)).not_nil!.body.should eq("hello")
    Corretto::Wire.read(IO::Memory.new("")).should be_nil
    Corretto::Wire.read(IO::Memory.new("not http\r\n\r\n")).should be_nil
  end

  it "answers Caramel::Outbound from stubs and fixtures, records requests " \
     "and refuses unstubbed ones" do
    with_wire do |wire|
      customers = "https://api.stripe.com/v1/customers"
      form = "email=a%40acme.test"
      wire.stub(customers, method: "post").to_return(
        status: 201,
        fixture: "stripe/customer_created.json",
        headers: {"Request-Id" => "req_123"},
      )
      authorization = HTTP::Headers{"Authorization" => "Bearer sk_test"}
      created = Caramel::Outbound.post(customers, authorization, form)
      created.status_code.should eq(201)
      created.body.should eq(File.read("spec/fixtures/wire/stripe/customer_created.json"))
      created.headers["Content-Type"].should eq("application/json")
      created.headers["Request-Id"].should eq("req_123")
      sent = wire.requests.last
      {sent.method, sent.url, sent.body}.should eq({"POST", customers, form})
      sent.headers["Host"].should eq("api.stripe.com")
      sent.headers["Authorization"].should eq("Bearer sk_test")

      # The stub is for POST only; other methods and URLs are unstubbed.
      listed = Caramel::Outbound.get("https://api.stripe.com/v1/customers")
      listed.status_code.should eq(502)
      listed.body.should eq("Unstubbed outbound request: GET https://api.stripe.com/v1/customers")
      twilio = "https://api.twilio.com:8443/x?y=1"
      unstubbed = Caramel::Outbound.get(twilio)
      unstubbed.body.should eq("Unstubbed outbound request: GET https://api.twilio.com:8443/x?y=1")
      wire.requests.last.headers["Host"].should eq("api.twilio.com:8443")

      wire.stub("https://api.stripe.com/v1/customers").to_return(status: 200, body: "any method")
      Caramel::Outbound.get("https://api.stripe.com/v1/customers").body.should eq("any method")
      Caramel::Outbound.post("https://api.stripe.com/v1/customers").body.should eq("any method")
      wire.requests.size.should eq(5)

      wire.reset
      wire.requests.should be_empty
      Caramel::Outbound.post("https://api.stripe.com/v1/customers").status_code.should eq(502)
    end
  end

  it "refuses fixture paths outside spec/fixtures/wire and missing fixtures" do
    with_wire do |wire|
      stub = wire.stub("https://api.stripe.com/v1/customers")
      expect_raises(ArgumentError, "relative paths") { stub.to_return(fixture: "../../shard.yml") }
      expect_raises(ArgumentError, "relative paths") { stub.to_return(fixture: "/etc/hosts") }
      missing = "spec/fixtures/wire/stripe/missing.json does not exist"
      expect_raises(Corretto::Error, missing) do
        stub.to_return(fixture: "stripe/missing.json")
      end
      expect_raises(ArgumentError, "not both") do
        stub.to_return(fixture: "stripe/customer_created.json", body: "x")
      end
      expect_raises(ArgumentError, "absolute URL") { wire.stub("/v1/customers") }
    end
  end
end

describe Caramel::Outbound do
  it "connects directly in origin form when no proxy is set" do
    received = Channel(String).new(1)
    server = HTTP::Server.new do |context|
      request = context.request
      body = request.body.try(&.gets_to_end)
      received.send("#{request.method} #{request.resource} #{body}")
      context.response.print("direct")
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    previous = Caramel::Outbound.proxy
    Caramel::Outbound.proxy = nil
    begin
      hooks = "http://127.0.0.1:#{address.port}/hooks?a=1"
      Caramel::Outbound.post(hooks, body: "ping").body.should eq("direct")
      received.receive.should eq("POST /hooks?a=1 ping")
      ["ftp://files.example/x", "https://api.example/a b"].each do |url|
        expect_raises(ArgumentError, "absolute http(s) URL") { Caramel::Outbound.get(url) }
      end
    ensure
      Caramel::Outbound.proxy = previous
      server.close
    end
  end
end
