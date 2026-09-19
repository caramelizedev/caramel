require "spec"
require "../../src/frappe/dev_gateway"

describe Caramel::Frappe::DevGateway do
  it "redacts a secret before cutting a long diagnostic at the output limit" do
    secret = "b" * 64
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel", [secret])
    gateway.failed("a" * 32730 + secret)
    page = gateway.handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "bookshelf.caramel"}))
    page.body.includes?("b" * 8).should be_false
  end

  it "serves escaped, private diagnostics and authenticates same-origin refresh" do
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel", ["very-private-secret"])
    gateway.failed("src/app.cr:3: undefined method <unsafe> very-private-secret")
    headers = HTTP::Headers{"Host" => "bookshelf.caramel"}
    page = gateway.handle(HTTP::Request.new("GET", "/books", headers))
    page.status.should eq(503)
    page.body.should contain("src/app.cr:3")
    page.body.should contain("&lt;unsafe&gt;")
    page.body.should_not contain("very-private-secret")
    page.headers["Cache-Control"].should eq("no-store")
    page.headers["Content-Security-Policy"].should contain("script-src 'self'")
    cookie = page.headers["Set-Cookie"]
    cookie.should contain("Secure")
    cookie.should contain("HttpOnly")
    cookie.should contain("SameSite=Strict")
    endpoint = "/__caramel/dev/status"
    gateway.handle(HTTP::Request.new("GET", endpoint, headers)).status.should eq(403)
    headers["Cookie"] = cookie.split(';').first
    gateway.handle(HTTP::Request.new("GET", endpoint, headers)).status.should eq(403)
    headers["X-Caramel-Dev"] = "1"
    response = gateway.handle(HTTP::Request.new("GET", endpoint, headers))
    response.status.should eq(200)
    JSON.parse(response.body)["state"].as_s.should eq("failed")
    headers["Origin"] = "https://evil.caramel"
    gateway.handle(HTTP::Request.new("GET", endpoint, headers)).status.should eq(403)
    headers["Host"] = "evil.caramel"
    gateway.handle(HTTP::Request.new("GET", "/", headers)).status.should eq(421)
  end

  it "advances refresh generations only for completed builds, failures and asset changes" do
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
    initial = gateway.generation
    gateway.building
    gateway.generation.should eq(initial)
    gateway.ready("/private/not-listening.sock")
    gateway.generation.should eq(initial + 1)
    gateway.assets_changed
    gateway.generation.should eq(initial + 2)
    gateway.failed("Build failed")
    gateway.generation.should eq(initial + 3)
    gateway.failed("Build failed")
    gateway.generation.should eq(initial + 3)
    page = gateway.handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "bookshelf.caramel"}))
    page.body.should contain("data-generation=\"#{gateway.generation}\"")
  end

  it "proxies the request and application cookies while adding development refresh only to full HTML" do
    directory = "/private/tmp/caramel-gateway-#{Random::Secure.hex(6)}"
    Dir.mkdir(directory, 0o700)
    socket_path = File.join(directory, "app.sock")
    upstream = HTTP::Server.new do |context|
      context.response.status_code = 201
      context.response.headers["Content-Type"] = "text/html; charset=utf-8"
      context.response.headers.add("Set-Cookie", "app_session=keep; Secure; HttpOnly")
      context.response.print("<!DOCTYPE html><body>#{context.request.method} #{context.request.resource} #{context.request.body.try(&.gets_to_end)}</body>")
    end
    upstream.bind_unix(socket_path)
    spawn { upstream.listen }
    begin
      gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
      gateway.ready(socket_path)
      headers = HTTP::Headers{"Host" => "bookshelf.caramel", "Content-Type" => "text/plain"}
      response = gateway.handle(HTTP::Request.new("POST", "/example?x=1", headers, "payload"))
      response.status.should eq(201)
      response.body.should contain("POST /example?x=1 payload")
      response.body.should contain("/__caramel/dev/client.js")
      response.headers["Set-Cookie"].should contain("app_session=keep")
      response.headers["Set-Cookie"].should contain("__Host-caramel_dev")
      headers["HX-Request-Type"] = "partial"
      fragment = gateway.handle(HTTP::Request.new("GET", "/example", headers))
      fragment.body.should_not contain("/__caramel/dev/client.js")
    ensure
      upstream.close
      File.delete?(socket_path)
      Dir.delete(directory)
    end
  end
end
