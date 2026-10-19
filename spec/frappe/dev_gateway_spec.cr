require "spec"
require "../../src/frappe/dev_gateway"

private HOST = HTTP::Headers{"Host" => "bookshelf.caramel"}

describe Caramel::Frappe::DevGateway do
  it "redacts a secret before cutting a long diagnostic at the output limit" do
    secret = "b" * 64
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel", [secret])
    gateway.failed("a" * 32730 + secret)
    host = HTTP::Headers{"Host" => "bookshelf.caramel"}
    page = gateway.handle(HTTP::Request.new("GET", "/", host))
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
    page.headers["Set-Cookie"]?.should be_nil
    endpoint = "/__caramel/dev/status"
    minimal = %w[generation state]
    full = %w[errors generation last_error latest state]
    keys = ->(request : HTTP::Headers) do
      response = gateway.handle(HTTP::Request.new("GET", endpoint, request))
      response.status.should eq(200)
      JSON.parse(response.body).as_h.keys.sort!
    end
    keys.call(headers).should eq(minimal)
    signed = gateway.handle(HTTP::Request.new("GET", gateway.sign_in_path, headers))
    headers["Cookie"] = signed.headers["Set-Cookie"].split(';').first
    keys.call(headers).should eq(minimal)
    headers["X-Caramel-Dev"] = "1"
    keys.call(headers).should eq(full)
    headers["Origin"] = "https://evil.caramel"
    keys.call(headers).should eq(minimal)
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
    host = HTTP::Headers{"Host" => "bookshelf.caramel"}
    page = gateway.handle(HTTP::Request.new("GET", "/", host))
    page.body.should contain("data-generation=\"#{gateway.generation}\"")
  end

  it "proxies the request and application cookies, adding dev refresh only to full HTML" do
    directory = "/private/tmp/caramel-gateway-#{Random::Secure.hex(6)}"
    Dir.mkdir(directory, 0o700)
    socket_path = File.join(directory, "app.sock")
    upstream = HTTP::Server.new do |context|
      context.response.status_code = 201
      context.response.headers["Content-Type"] = "text/html; charset=utf-8"
      context.response.headers.add("Set-Cookie", "app_session=keep; Secure; HttpOnly")
      request = context.request
      echo = "#{request.method} #{request.resource} #{request.body.try(&.gets_to_end)}"
      context.response.print("<!DOCTYPE html><body>#{echo}</body>")
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
      response.headers["Set-Cookie"].should_not contain("__Host-caramel_dev")
      headers["HX-Request-Type"] = "partial"
      fragment = gateway.handle(HTTP::Request.new("GET", "/example", headers))
      fragment.body.should_not contain("/__caramel/dev/client.js")
    ensure
      upstream.close
      File.delete?(socket_path)
      Dir.delete(directory)
    end
  end

  it "names the upstream's request in the script it adds to a full page" do
    directory = "/private/tmp/caramel-gateway-#{Random::Secure.hex(6)}"
    Dir.mkdir(directory, 0o700)
    socket_path = File.join(directory, "app.sock")
    upstream = HTTP::Server.new do |context|
      context.response.headers["Content-Type"] = "text/html; charset=utf-8"
      context.response.headers["X-Request-ID"] = "abcdef12"
      context.response.print("<!DOCTYPE html><body>page</body>")
    end
    upstream.bind_unix(socket_path)
    spawn { upstream.listen }
    begin
      gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
      gateway.ready(socket_path)
      host = HTTP::Headers{"Host" => "bookshelf.caramel"}
      response = gateway.handle(HTTP::Request.new("GET", "/", host))
      response.body.should contain("data-request=\"abcdef12\"")
    ensure
      upstream.close
      File.delete?(socket_path)
      Dir.delete(directory)
    end
  end

  it "links each compiler diagnostic to the editor and keeps the raw output folded" do
    editor = Caramel::Crema::Editor.from("zed")
    origin = "https://bookshelf.caramel"
    gateway = Caramel::Frappe::DevGateway.new(origin, [] of String, editor, "/proj")
    diagnostic = Caramel::Frappe::Diagnostic.new("UNDEFINED_METHOD", "app/a.cr", 3, 7,
      "undefined method 'foo'", remediation: "check the name", source: "  foo")
    gateway.failed("raw compiler output", [diagnostic])
    host = HTTP::Headers{"Host" => "bookshelf.caramel"}
    page = gateway.handle(HTTP::Request.new("GET", "/", host))
    page.body.should contain("<a href=\"zed://file/proj/app/a.cr:3:7\">app/a.cr:3:7</a>")
    folded = "<details><summary>Compiler output</summary><pre>raw compiler output</pre>"
    page.body.should contain(folded)
  end

  it "reports the newest trace in its status" do
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
    owner = HTTP::Headers{
      "Host"                  => "bookshelf.caramel",
      "X-Caramel-Owner-Token" => gateway.owner_token,
    }
    status = gateway.handle(HTTP::Request.new("GET", "/__caramel/dev/status", owner))
    document = JSON.parse(status.body)
    document.as_h.keys.sort!.should eq(%w[errors generation last_error latest state])
    {document["latest"].as_i, document["errors"].as_i}.should eq({0, 0})
    document["last_error"].raw.should be_nil
  end

  it "forwards bodiless responses without reading or decorating a body" do
    directory = "/private/tmp/caramel-gateway-#{Random::Secure.hex(6)}"
    Dir.mkdir(directory, 0o700)
    socket_path = File.join(directory, "app.sock")
    page = "<!DOCTYPE html><body>page</body>"
    upstream = HTTP::Server.new do |context|
      context.response.headers["Content-Type"] = "text/html; charset=utf-8"
      case context.request.path
      when "/notes/1" then context.response.status_code = 204
      when "/cached"  then context.response.status_code = 304
      else                 context.response.print(page)
      end
    end
    upstream.bind_unix(socket_path)
    spawn { upstream.listen }
    begin
      gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
      gateway.ready(socket_path)
      headers = HTTP::Headers{"Host" => "bookshelf.caramel"}
      bodiless = {"DELETE" => {"/notes/1", 204}, "GET" => {"/cached", 304}}
      bodiless.each do |method, (path, status)|
        response = gateway.handle(HTTP::Request.new(method, path, headers))
        response.status.should eq(status)
        response.body.should eq("")
        response.headers["Content-Length"]?.should be_nil
      end
      head = gateway.handle(HTTP::Request.new("HEAD", "/page", headers))
      head.status.should eq(200)
      head.body.should eq("")
      head.headers["Content-Length"].should eq(page.bytesize.to_s)
      gateway.state.should eq("ready")
    ensure
      upstream.close
      File.delete?(socket_path)
      Dir.delete(directory)
    end
  end

  it "streams upstream event streams without buffering them" do
    directory = "/private/tmp/caramel-gateway-#{Random::Secure.hex(6)}"
    Dir.mkdir(directory, 0o700)
    socket_path = File.join(directory, "app.sock")
    gate = Channel(Nil).new
    upstream = HTTP::Server.new do |context|
      context.response.headers["Content-Type"] = "text/event-stream"
      context.response.print("data: one\n\n")
      context.response.flush
      gate.receive
      context.response.print("data: two\n\n")
    end
    upstream.bind_unix(socket_path)
    spawn { upstream.listen }
    begin
      gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
      gateway.ready(socket_path)
      host = HTTP::Headers{"Host" => "bookshelf.caramel"}
      response = gateway.handle(HTTP::Request.new("GET", "/events", host))
      response.streamer.should_not be_nil
      response.headers["Content-Type"].should eq("text/event-stream")
      reader, writer = IO.pipe
      spawn do
        response.streamer.not_nil!.call(writer)
        writer.close
      end
      line = Channel(String?).new(1)
      spawn { line.send(reader.gets) }
      select
      when value = line.receive
        value.should eq("data: one")
      when timeout(2.seconds)
        fail "timed out waiting for the first proxied event"
      end
      gate.send(nil)
      lines = [] of String
      while text = reader.gets(chomp: true)
        lines << text
        break if text == "data: two"
      end
      lines.should contain("data: two")
    ensure
      upstream.close
      File.delete?(socket_path)
      Dir.delete(directory)
    end
  end

  it "hands out a sign-in link whose cookie it sets once and never on a page" do
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
    path = gateway.sign_in_path
    path.should match(/\A\/__caramel\/dev\/sign-in\?nonce=[0-9a-f]{64}\z/)
    signed = gateway.handle(HTTP::Request.new("GET", path, HOST))
    signed.status.should eq(303)
    signed.headers["Location"].should eq("/")
    cookie = signed.headers["Set-Cookie"]
    ["__Host-caramel_dev=", "Secure", "HttpOnly", "SameSite=Strict", "path=/"].each do |part|
      cookie.should contain(part)
    end
    cookie.should_not contain("Max-Age")
    cookie.should_not contain("Expires")
    again = gateway.handle(HTTP::Request.new("GET", path, HOST))
    again.status.should eq(403)
    again.body.should eq(Caramel::Frappe::DevGateway::SIGN_IN_REFUSED)
    again.headers["Set-Cookie"]?.should be_nil
  end

  it "refuses a sign-in with a wrong or missing nonce" do
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
    gateway.sign_in_path
    sign_in = Caramel::Frappe::DevGateway::SIGN_IN
    ["", "?nonce=", "?nonce=#{"0" * 64}", "?nonce=short"].each do |query|
      response = gateway.handle(HTTP::Request.new("GET", sign_in + query, HOST))
      response.status.should eq(403)
      response.headers["Set-Cookie"]?.should be_nil
    end
  end

  it "keeps at most eight sign-in links, retiring the oldest" do
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
    paths = Array.new(9) { gateway.sign_in_path }
    first = gateway.handle(HTTP::Request.new("GET", paths.first, HOST))
    first.status.should eq(403)
    paths.skip(1).each do |path|
      gateway.handle(HTTP::Request.new("GET", path, HOST)).status.should eq(303)
    end
  end

  it "mints a sign-in link for the owner token and for nothing else" do
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
    link = Caramel::Frappe::DevGateway::SIGN_IN_LINK
    owner = HOST.dup
    owner["X-Caramel-Owner-Token"] = gateway.owner_token
    minted = gateway.handle(HTTP::Request.new("GET", link, owner))
    minted.status.should eq(200)
    path = JSON.parse(minted.body)["path"].as_s
    gateway.handle(HTTP::Request.new("GET", path, HOST)).status.should eq(303)
    cookie = gateway.handle(HTTP::Request.new("GET", gateway.sign_in_path, HOST))
    session = HOST.dup
    session["Cookie"] = cookie.headers["Set-Cookie"].split(';').first
    session["X-Caramel-Dev"] = "1"
    gateway.handle(HTTP::Request.new("GET", link, session)).status.should eq(403)
    gateway.handle(HTTP::Request.new("GET", link, HOST)).status.should eq(403)
    wrong = HOST.dup
    wrong["X-Caramel-Owner-Token"] = "0" * 64
    gateway.handle(HTTP::Request.new("GET", link, wrong)).status.should eq(403)
  end

  it "serves its assets without a sign-in and sets no cookie on a build page" do
    gateway = Caramel::Frappe::DevGateway.new("https://bookshelf.caramel")
    ["inspector.css", "theme.js", "client.js", "toolbar.css", "style.css"].each do |asset|
      response = gateway.handle(HTTP::Request.new("GET", "/__caramel/dev/#{asset}", HOST))
      response.status.should eq(200)
    end
    building = gateway.handle(HTTP::Request.new("GET", "/", HOST))
    building.status.should eq(503)
    building.headers["Set-Cookie"]?.should be_nil
  end
end
