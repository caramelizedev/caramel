require "spec"
require "openssl/hmac"
require "crypto/subtle"
require "../../src/caramel"

private INGRESS_SECRET = "webhook-secret"

abstract struct IngressSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

module IngressSpec
  class_property handled = 0
end

# A signed webhook: exact bytes, no browser CSRF, HMAC over the timestamp and body.
struct IngressSpecInbox < IngressSpecAction
  ingress body: :raw, limit: 64, csrf: false, authenticate: :signed?

  contract do
    field source : String?
  end

  def handle(contract : Contract)
    IngressSpec.handled += 1
    session["seen"] = "yes"
    Caramel::Response.new(202, "#{contract.source}:#{String.new(raw_body)}")
  end

  private def signed? : Bool
    timestamp = request.headers["X-Timestamp"]? || return false
    signature = request.headers["X-Signature"]? || return false
    expected = OpenSSL::HMAC.hexdigest(:sha256, INGRESS_SECRET, "#{timestamp}.#{String.new(raw_body)}")
    Crypto::Subtle.constant_time_compare(signature, expected)
  end
end

# A token API shared by several actions.
abstract struct IngressSpecApi < IngressSpecAction
  ingress csrf: false, authenticate: :token?

  private def token? : Bool
    request.headers["Authorization"]? == "Bearer api-token"
  end
end

struct IngressSpecCreateNote < IngressSpecApi
  contract do
    field title : String
    field pages : Int32
  end

  def handle(contract : Contract)
    session["user_id"] = "1"
    json({title: contract.title, pages: contract.pages, session: session.to_a}, 201)
  end
end

struct IngressSpecShowNote < IngressSpecApi
  contract do
    field id : Int64
  end

  def handle(contract : Contract)
    json({id: contract.id})
  end
end

struct IngressSpecDeleteNote < IngressSpecApi
  contract do
    field id : Int64
  end

  def handle(contract : Contract)
    Caramel::Response.new(204)
  end
end

# The browser default, which now also binds same-origin JSON.
struct IngressSpecCreateBook < IngressSpecAction
  contract do
    field title : String
  end

  def handle(contract : Contract)
    session["last"] = contract.title
    Caramel::Response.new(201, contract.title)
  end
end

module IngressSpecApp
  Caramel::Router.draw do
    post "/hooks/inbox", IngressSpecInbox
    post "/notes", IngressSpecCreateNote
    get "/notes/:id", IngressSpecShowNote
    delete "/notes/:id", IngressSpecDeleteNote
    post "/books", IngressSpecCreateBook
  end
end

private INGRESS_CSRF = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
private INGRESS_APP  = Caramel::Application.new(IngressSpecApp::AppRouter.new, INGRESS_CSRF)

private def ingress_request(method : String, path : String, body : String? = nil, headers = HTTP::Headers.new) : Caramel::Response
  headers["Host"] = "bookshelf.caramel"
  INGRESS_APP.handle(HTTP::Request.new(method, path, headers, body))
end

private def signed(body : String, timestamp = "1727600000") : HTTP::Headers
  HTTP::Headers{"Content-Type" => "application/json", "X-Timestamp" => timestamp,
                "X-Signature" => OpenSSL::HMAC.hexdigest(:sha256, INGRESS_SECRET, "#{timestamp}.#{body}")}
end

private def browser_headers(token = INGRESS_CSRF.issue) : HTTP::Headers
  HTTP::Headers{"Origin" => "https://bookshelf.caramel", "Cookie" => "#{Caramel::CSRF::COOKIE_NAME}=#{token}", "X-CSRF-Token" => token}
end

describe "Caramel::Action ingress" do
  it "hands a signed webhook its exact bytes without a browser CSRF token" do
    body = %({"event_id":"evt_1",  "amount":1})
    response = ingress_request("POST", "/hooks/inbox?source=relay", body, signed(body))
    response.status.should eq(202)
    response.body.should eq("relay:#{body}")
    response.headers["Set-Cookie"]?.should be_nil
  end

  it "refuses a missing or wrong signature with 401 before the contract binds or the action runs" do
    body = %({"event_id":"evt_2"})
    before = IngressSpec.handled
    tampered = signed(body)
    tampered["X-Signature"] = "0" * 64
    ingress_request("POST", "/hooks/inbox", body, tampered).status.should eq(401)
    ingress_request("POST", "/hooks/inbox?unknown=1", body, HTTP::Headers{"Content-Type" => "application/json"}).status.should eq(401)
    IngressSpec.handled.should eq(before)
    ingress_request("POST", "/hooks/inbox?unknown=1", body, signed(body)).status.should eq(422)
  end

  it "answers 413 for a body over the declared limit" do
    body = "x" * 65
    ingress_request("POST", "/hooks/inbox", body, signed(body)).status.should eq(413)
  end

  it "lets a token API skip CSRF, with an empty session it never saves" do
    headers = HTTP::Headers{"Content-Type" => "application/json", "Authorization" => "Bearer api-token", "Accept" => "application/json",
                            "Origin" => "https://elsewhere.example", "Cookie" => "#{Caramel::Session::COOKIE_NAME}=#{INGRESS_APP.sessions.cookie({"user_id" => "9"}).value}"}
    created = ingress_request("POST", "/notes", %({"title": "Dune", "pages": 412}), headers)
    created.status.should eq(201)
    JSON.parse(created.body).should eq(JSON.parse(%({"title": "Dune", "pages": 412, "session": [["user_id", "1"]]})))
    created.headers["Set-Cookie"]?.should be_nil
    ingress_request("POST", "/notes", %({"title": "Dune", "pages": "412"}), headers).body.should contain("must be a JSON number")
    headers.delete("Authorization")
    ingress_request("POST", "/notes", %({"title": "Dune", "pages": 412}), headers).status.should eq(401)
  end

  it "authenticates reads too" do
    authorized = HTTP::Headers{"Authorization" => "Bearer api-token", "Accept" => "application/json"}
    ingress_request("GET", "/notes/5", headers: authorized).body.should eq(%({"id":5}))
    head = ingress_request("HEAD", "/notes/5", headers: authorized)
    {head.status, head.body}.should eq({200, ""})
    ingress_request("GET", "/notes/5").status.should eq(401)
    ingress_request("HEAD", "/notes/5").status.should eq(401)
  end

  it "binds same-origin JSON on default routes only with the CSRF header" do
    body = %({"title": "Dune"})
    json = HTTP::Headers{"Content-Type" => "application/json"}
    ingress_request("POST", "/books", body, json).status.should eq(403)
    token = INGRESS_CSRF.issue
    in_body = browser_headers(token).tap(&.delete("X-CSRF-Token")).tap(&.[]=("Content-Type", "application/json"))
    ingress_request("POST", "/books", %({"title": "Dune", "_csrf": "#{token}"}), in_body).status.should eq(403)
    accepted = ingress_request("POST", "/books", body, browser_headers.tap(&.[]=("Content-Type", "application/json")))
    {accepted.status, accepted.body}.should eq({201, "Dune"})
    accepted.headers["Set-Cookie"].should start_with(Caramel::Session::COOKIE_NAME)
  end

  it "never lets a route's CSRF setting reach a request its route did not match" do
    form = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded", "Authorization" => "Bearer api-token"}
    ingress_request("POST", "/nowhere", "a=1", form.dup).status.should eq(403)
    # Only DELETE /notes/:id turns CSRF off; a POST there is checked, then 405.
    ingress_request("POST", "/notes/5", "a=1", form.dup).status.should eq(403)
    ingress_request("POST", "/notes/5", "a=1", browser_headers.tap(&.[]=("Content-Type", "application/x-www-form-urlencoded"))).status.should eq(405)
  end

  it "refuses a method override into a route that reads its body differently" do
    headers = browser_headers.tap(&.[]=("Content-Type", "application/x-www-form-urlencoded"))
    headers["Authorization"] = "Bearer api-token"
    refused = ingress_request("POST", "/notes/5", "_method=DELETE", headers)
    refused.status.should eq(405)
    refused.headers["Allow"].should eq("GET, HEAD, DELETE")
  end

  it "lists a route's non-default ingress" do
    entries = IngressSpecApp::AppRouter.routes
    entries.find!(&.action.==("IngressSpecInbox")).ingress.summary.should eq("raw, 64 bytes, csrf off, authenticate signed?")
    entries.find!(&.action.==("IngressSpecShowNote")).ingress.summary.should eq("csrf off, authenticate token?")
    entries.find!(&.action.==("IngressSpecCreateBook")).ingress.should eq(Caramel::Ingress::DEFAULT)
  end
end
