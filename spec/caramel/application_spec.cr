require "spec"
require "../../src/caramel"
require "file_utils"

abstract struct ApplicationSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

struct ApplicationSpecHello < ApplicationSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "hello")
  end
end

struct ApplicationSpecBroken < ApplicationSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    raise "database password=do-not-disclose"
  end
end

module ApplicationSpecApp
  Caramel::Router.draw do
    get "/", ApplicationSpecHello
    get "/broken", ApplicationSpecBroken
  end
end

private def application_spec_app(root : String? = nil) : Caramel::Application
  csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
  Caramel::Application.new(ApplicationSpecApp::AppRouter.new, csrf, root)
end

# A request addressed to the application's configured host, or to `host`.
private def hosted_request(method : String,
                           path : String,
                           host : String = "bookshelf.caramel") : HTTP::Request
  HTTP::Request.new(method, path, HTTP::Headers{"Host" => host})
end

describe Caramel::Application do
  it "checks the configured Host and adds browser security headers" do
    app = application_spec_app
    good = app.handle(hosted_request("GET", "/"))
    good.body.should eq("hello")
    good.headers["X-Content-Type-Options"].should eq("nosniff")
    app.handle(hosted_request("GET", "/", host: "evil.example")).status.should eq(421)
  end

  it "returns a traceable error without exposing an exception or secrets" do
    app = application_spec_app
    response = app.handle(hosted_request("GET", "/broken"))
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
      app = application_spec_app("#{root}/public")
      ["/../secret", "/%2e%2e/secret", "/link", "/.env", "/app/"].each do |path|
        app.handle(hosted_request("GET", path)).status.should eq(404)
      end
      app.handle(hosted_request("GET", "foo")).status.should eq(400)
      app.handle(hosted_request("GET", "/app.css")).body.should eq("body{}")
      app.handle(hosted_request("POST", "/app.css")).status.should eq(405)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
