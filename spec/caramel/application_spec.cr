require "spec"
require "../../src/caramel/application"
require "file_utils"

describe Caramel::Application do
  it "checks the configured Host and adds browser security headers" do
    router = Caramel::Router.new
    router.get("/") { |_, _| Caramel::Response.new(body: "hello") }
    app = Caramel::Application.new(router, "https://bookshelf.caramel")
    good = app.handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "bookshelf.caramel"}))
    good.body.should eq("hello")
    good.headers["X-Content-Type-Options"].should eq("nosniff")
    app.handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "evil.example"})).status.should eq(421)
  end

  it "returns a traceable error without exposing an exception or secrets" do
    router = Caramel::Router.new
    router.get("/") { |_, _| raise "database password=do-not-disclose"; Caramel::Response.new }
    app = Caramel::Application.new(router, "https://bookshelf.caramel")
    response = app.handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "bookshelf.caramel"}))
    response.status.should eq(500)
    response.body.should_not contain("do-not-disclose")
    response.headers["X-Request-ID"].should match(/\A[0-9a-f-]{36}\z/)
    response.body.should contain(response.headers["X-Request-ID"])
    response.headers["Cache-Control"].should eq("no-store")
  end

  it "serves only public regular files and refuses traversal or escaping symlinks" do
    root = File.tempname("caramel-public")
    Dir.mkdir(root)
    Dir.mkdir("#{root}/public")
    File.write("#{root}/public/app.css", "body{}")
    File.write("#{root}/public/.foo", "hidden")
    File.write("#{root}/secret", "private")
    File.symlink("#{root}/secret", "#{root}/public/link")
    begin
      app = Caramel::Application.new(Caramel::Router.new, "https://bookshelf.caramel", "#{root}/public")
      ["/../secret", "/%2e%2e/secret", "/link", "/.env", "/app/"].each do |path|
        app.handle(HTTP::Request.new("GET", path, HTTP::Headers{"Host" => "bookshelf.caramel"})).status.should eq(404)
      end
      app.handle(HTTP::Request.new("GET", "foo", HTTP::Headers{"Host" => "bookshelf.caramel"})).status.should eq(400)
      app.handle(HTTP::Request.new("GET", "/app.css", HTTP::Headers{"Host" => "bookshelf.caramel"})).body.should eq("body{}")
      app.handle(HTTP::Request.new("POST", "/app.css", HTTP::Headers{"Host" => "bookshelf.caramel"})).status.should eq(405)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
