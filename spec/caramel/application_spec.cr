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

struct ApplicationSpecFramed < ApplicationSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    content_security_policy.add("frame-src", "https://player.example")
    Caramel::Response.new(body: "framed")
  end
end

struct ApplicationSpecNonced < ApplicationSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: csp_nonce)
  end
end

struct ApplicationSpecOwn < ApplicationSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    headers = HTTP::Headers{"Content-Security-Policy" => "default-src 'none'"}
    Caramel::Response.new(body: "own", headers: headers)
  end
end

module ApplicationSpecApp
  Caramel::Router.draw do
    get "/", ApplicationSpecHello
    get "/broken", ApplicationSpecBroken
    get "/framed", ApplicationSpecFramed
    get "/nonced", ApplicationSpecNonced
    get "/own", ApplicationSpecOwn
  end
end

private def application_spec_app(root : String? = nil,
                                 policy = Caramel.content_security_policy,
                                 hsts : Bool = false) : Caramel::Application
  csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
  Caramel::Application.new(ApplicationSpecApp::AppRouter.new, csrf, root, policy, hsts)
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

  it "carries the default policy and no Strict-Transport-Security unless asked" do
    response = application_spec_app.handle(hosted_request("GET", "/"))
    default = Caramel::ContentSecurityPolicy.default.to_s
    response.headers["Content-Security-Policy"].should eq(default)
    response.headers.has_key?("Strict-Transport-Security").should be_false
  end

  it "carries the policy an action changed for its own response only" do
    app = application_spec_app
    framed = app.handle(hosted_request("GET", "/framed"))
    policy = framed.headers["Content-Security-Policy"]
    policy.should contain("frame-src 'self' https://player.example")
    later = app.handle(hosted_request("GET", "/"))
    later.headers["Content-Security-Policy"].should_not contain("frame-src")
  end

  it "adds a fresh nonce to script-src and style-src when an action takes one" do
    app = application_spec_app
    first = app.handle(hosted_request("GET", "/nonced"))
    second = app.handle(hosted_request("GET", "/nonced"))
    nonce = first.body
    policy = first.headers["Content-Security-Policy"]
    policy.should contain("script-src 'self' 'nonce-#{nonce}';")
    policy.should contain("style-src 'self' 'nonce-#{nonce}';")
    second.body.should_not eq(nonce)
  end

  it "keeps a Content-Security-Policy header an action set itself" do
    response = application_spec_app.handle(hosted_request("GET", "/own"))
    response.headers["Content-Security-Policy"].should eq("default-src 'none'")
  end

  it "sends the application's own policy on every response, a 421 too" do
    policy = Caramel::ContentSecurityPolicy.default.add("script-src", "https://js.stripe.com")
    app = application_spec_app(policy: policy)
    stripe = "script-src 'self' https://js.stripe.com;"
    app.handle(hosted_request("GET", "/")).headers["Content-Security-Policy"].should contain(stripe)
    refused = app.handle(hosted_request("GET", "/", host: "evil.example"))
    refused.status.should eq(421)
    refused.headers["Content-Security-Policy"].should contain(stripe)
  end

  it "sends Strict-Transport-Security on every response when built with hsts" do
    app = application_spec_app(hsts: true)
    app.handle(hosted_request("GET", "/")).headers["Strict-Transport-Security"]
      .should eq("max-age=31536000")
    refused = app.handle(hosted_request("GET", "/", host: "evil.example"))
    refused.headers["Strict-Transport-Security"].should eq("max-age=31536000")
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
