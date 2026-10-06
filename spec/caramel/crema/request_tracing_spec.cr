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

# Keeps the `handled` flag of the error each finished trace holds, if any.
class ErrorCaptureSink < Caramel::Crema::Sink
  getter handled = [] of Bool?

  def name : String
    "error-capture"
  end

  def finished(trace : Caramel::Crema::Trace) : Nil
    @handled << trace.error.try(&.handled?)
  end
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

  it "names a trace after a known method, and OTHER for any other label" do
    names = {} of String => String
    ["GET", "BREW"].each do |method|
      Caramel::Crema.request(HTTP::Request.new(method, "/x")) do |trace|
        names[method] = trace.name
        Caramel::Response.new(body: "ok")
      end
    end
    names.should eq({"GET" => "GET (none)", "BREW" => "OTHER (none)"})
  end

  it "takes the sampled bit from the inbound traceparent and a job's context" do
    header = HTTP::Headers{"traceparent" => "00-#{"a" * 32}-#{"b" * 16}-00"}
    Caramel::Crema.request(HTTP::Request.new("GET", "/x", header)) do |trace|
      trace.sampled?.should be_false
      trace.parent_sampled.should be_false
      Caramel::Response.new(body: "ok")
    end
    context = %({"traceparent":"00-#{"a" * 32}-#{"b" * 16}-01"})
    Caramel::Crema.job(1_i64, "App::Job", "default", 1, Time.utc, context) do |trace|
      trace.sampled?.should be_true
      trace.parent_sampled.should be_true
    end
  end

  it "marks only unhandled reports as reported, and clears the mark when the trace ends" do
    error = KeyError.new("x")
    Caramel::Crema.request(HTTP::Request.new("GET", "/x")) do
      Caramel::Crema.report(error, handled: true)
      Caramel::Crema.reported?(error).should be_false
      Caramel::Crema.report(error, handled: false)
      Caramel::Crema.reported?(error).should be_true
      Caramel::Response.new(body: "ok")
    end
    Caramel::Crema.reported?(error).should be_false
  end

  it "still records the unhandled error when a handled report is raised again" do
    sink = Caramel::Crema.subscribe(ErrorCaptureSink.new).as(ErrorCaptureSink)
    begin
      expect_raises(KeyError) do
        Caramel::Crema.request(HTTP::Request.new("GET", "/x")) do
          error = KeyError.new("x")
          Caramel::Crema.report(error, handled: true)
          raise error
        end
      end
    ensure
      Caramel::Crema.unsubscribe(sink)
    end
    sink.handled.should eq([false])
  end
end
