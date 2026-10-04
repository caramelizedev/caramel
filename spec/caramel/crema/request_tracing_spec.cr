require "spec"
require "log/spec"
require "../../../src/caramel"

abstract struct CremaSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

struct CremaSpecShow < CremaSpecAction
  contract do
    field id : Int64, min: 1
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "book #{contract.id}")
  end
end

struct CremaSpecBroken < CremaSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    raise KeyError.new("database password=do-not-disclose")
  end
end

module CremaSpecApp
  Caramel::Router.draw do
    get "/books/:id", CremaSpecShow
    get "/broken", CremaSpecBroken
  end
end

private def crema_app : Caramel::Application
  csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
  Caramel::Application.new(CremaSpecApp::AppRouter.new, csrf)
end

private def crema_request(path : String, headers : Hash(String, String) = {} of String => String)
  all = HTTP::Headers{"Host" => "bookshelf.caramel"}
  headers.each { |name, value| all[name] = value }
  HTTP::Request.new("GET", path, all)
end

private def canonical(logs : Log::EntriesChecker, message : String) : Log::Entry
  logs.check(:info, message)
  logs.entry
end

describe "Crema request tracing" do
  it "gives every response a request id: 200, 404 and 500" do
    ["/books/7", "/missing", "/broken"].each do |path|
      response = crema_app.handle(crema_request(path))
      response.headers["X-Request-ID"].should match(/\A[0-9a-f-]{36}\z/)
    end
  end

  it "echoes a valid inbound request id" do
    response = crema_app.handle(crema_request("/books/7", {"X-Request-ID" => "check-0001"}))
    response.headers["X-Request-ID"].should eq("check-0001")
  end

  it "replaces an inbound request id that is not a plain token" do
    response = crema_app.handle(crema_request("/books/7", {"X-Request-ID" => "bad id"}))
    response.headers["X-Request-ID"].should match(/\A[0-9a-f-]{36}\z/)
  end

  it "continues the trace of a valid traceparent" do
    trace_id = "0af7651916cd43dd8448eb211c80319c"
    parent = "b7ad6b7169203331"
    header = {"traceparent" => "00-#{trace_id}-#{parent}-01"}
    Log.capture("crema") do |logs|
      crema_app.handle(crema_request("/books/7", header))
      data = canonical(logs, "request").data
      data[:trace_id].should eq(trace_id)
      data[:parent_id].should eq(parent)
    end
  end

  it "logs one canonical line with the route, action and status, and no path" do
    Log.capture("crema") do |logs|
      crema_app.handle(crema_request("/books/7"))
      data = canonical(logs, "request").data
      data[:name].should eq("GET /books/:id")
      data[:route].should eq("/books/:id")
      data[:action].should eq("CremaSpecShow")
      data[:status].should eq(200)
      data[:path]?.should be_nil
    end
  end

  it "reports an unhandled error with its class and fingerprint but not its message" do
    Log.capture("crema") do |logs|
      crema_app.handle(crema_request("/broken"))
      logs.check(:error, "error")
      data = logs.entry.data
      data[:error_class].should eq("KeyError")
      data[:fingerprint].to_s.should match(/\A[0-9a-f]{12}\z/)
      data[:message]?.should be_nil
      data.to_s.should_not contain("do-not-disclose")
      canonical(logs, "request").data[:outcome].should eq("error")
    end
  end

  it "names an unmatched request after the missing route" do
    Log.capture("crema") do |logs|
      crema_app.handle(crema_request("/missing"))
      canonical(logs, "request").data[:name].should eq("GET (none)")
    end
  end
end
