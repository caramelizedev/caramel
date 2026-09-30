require "spec"
require "openssl/hmac"
require "crypto/subtle"
require "../../src/caramel"

module IngressSpec
  SECRET = "webhook-secret"

  class_property handled = 0

  def self.signature(timestamp : String, body : String) : String
    OpenSSL::HMAC.hexdigest(:sha256, SECRET, "#{timestamp}.#{body}")
  end
end

abstract struct IngressSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
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
    expected = IngressSpec.signature(timestamp, String.new(raw_body))
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

# Its own ingress replaces the API's entirely, authenticator included.
struct IngressSpecNoteForm < IngressSpecApi
  ingress limit: 1.kilobyte

  contract do
    field title : String
  end

  def handle(contract : Contract)
    Caramel::Response.new(201, contract.title)
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
    post "/notes/form", IngressSpecNoteForm
  end
end

private INGRESS_CSRF   = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
private INGRESS_ROUTER = IngressSpecApp::AppRouter.new
private INGRESS_APP    = Caramel::Application.new(INGRESS_ROUTER, INGRESS_CSRF)

private JSON_TYPE = "application/json"
private FORM_TYPE = "application/x-www-form-urlencoded"
private BEARER    = "Bearer api-token"

private def ingress_request(method : String, path : String, body : String? = nil,
                            headers = HTTP::Headers.new) : Caramel::Response
  headers["Host"] = "bookshelf.caramel"
  INGRESS_APP.handle(HTTP::Request.new(method, path, headers, body))
end

private def signed(body : String, timestamp = "1727600000") : HTTP::Headers
  HTTP::Headers{
    "Content-Type" => JSON_TYPE,
    "X-Timestamp"  => timestamp,
    "X-Signature"  => IngressSpec.signature(timestamp, body),
  }
end

# A same-origin browser request with the CSRF cookie and its header.
private def browser(content_type : String, token = INGRESS_CSRF.issue) : HTTP::Headers
  HTTP::Headers{
    "Content-Type" => content_type,
    "Origin"       => "https://bookshelf.caramel",
    "Cookie"       => "#{Caramel::CSRF::COOKIE_NAME}=#{token}",
    "X-CSRF-Token" => token,
  }
end

private def ingress_of(action : String) : Caramel::Ingress
  IngressSpecApp::AppRouter.routes.find!(&.action.==(action)).ingress
end

describe "Caramel::Action ingress" do
  it "hands a signed webhook its exact bytes without a browser CSRF token" do
    body = %({"event_id":"evt_1",  "amount":1})
    response = ingress_request("POST", "/hooks/inbox?source=relay", body, signed(body))
    response.status.should eq(202)
    response.body.should eq("relay:#{body}")
    response.headers["Set-Cookie"]?.should be_nil
  end

  it "answers 401 to a bad signature before the contract binds or the action runs" do
    body = %({"event_id":"evt_2"})
    before = IngressSpec.handled
    tampered = signed(body)
    tampered["X-Signature"] = "0" * 64
    unsigned = HTTP::Headers{"Content-Type" => JSON_TYPE}

    ingress_request("POST", "/hooks/inbox", body, tampered).status.should eq(401)
    ingress_request("POST", "/hooks/inbox?unknown=1", body, unsigned).status.should eq(401)
    IngressSpec.handled.should eq(before)
    unknown = ingress_request("POST", "/hooks/inbox?unknown=1", body, signed(body))
    unknown.status.should eq(422)
  end

  it "answers 413 for a body over the declared limit" do
    body = "x" * 65
    ingress_request("POST", "/hooks/inbox", body, signed(body)).status.should eq(413)
  end

  it "lets a token API skip CSRF, with an empty session it never saves" do
    cookie = INGRESS_APP.sessions.cookie({"user_id" => "9"}).value
    headers = HTTP::Headers{
      "Content-Type"  => JSON_TYPE,
      "Accept"        => JSON_TYPE,
      "Authorization" => BEARER,
      "Origin"        => "https://elsewhere.example",
      "Cookie"        => "#{Caramel::Session::COOKIE_NAME}=#{cookie}",
    }
    note = %({"title": "Dune", "pages": 412})

    created = ingress_request("POST", "/notes", note, headers)
    created.status.should eq(201)
    created.headers["Set-Cookie"]?.should be_nil
    saved = %({"title": "Dune", "pages": 412, "session": [["user_id", "1"]]})
    JSON.parse(created.body).should eq(JSON.parse(saved))

    quoted = %({"title": "Dune", "pages": "412"})
    mistyped = ingress_request("POST", "/notes", quoted, headers)
    mistyped.body.should contain("must be a JSON number")

    headers.delete("Authorization")
    ingress_request("POST", "/notes", note, headers).status.should eq(401)
  end

  it "authenticates reads too" do
    authorized = HTTP::Headers{"Authorization" => BEARER, "Accept" => JSON_TYPE}
    ingress_request("GET", "/notes/5", headers: authorized).body.should eq(%({"id":5}))
    head = ingress_request("HEAD", "/notes/5", headers: authorized)
    {head.status, head.body}.should eq({200, ""})
    ingress_request("GET", "/notes/5").status.should eq(401)
    ingress_request("HEAD", "/notes/5").status.should eq(401)
  end

  it "binds same-origin JSON on default routes only with the CSRF header" do
    body = %({"title": "Dune"})
    json = HTTP::Headers{"Content-Type" => JSON_TYPE}
    ingress_request("POST", "/books", body, json).status.should eq(403)

    # In a JSON body, `_csrf` is only a field; the token belongs in the header.
    token = INGRESS_CSRF.issue
    cookie_only = browser(JSON_TYPE, token)
    cookie_only.delete("X-CSRF-Token")
    with_field = %({"title": "Dune", "_csrf": "#{token}"})
    ingress_request("POST", "/books", with_field, cookie_only).status.should eq(403)

    accepted = ingress_request("POST", "/books", body, browser(JSON_TYPE))
    {accepted.status, accepted.body}.should eq({201, "Dune"})
    accepted.headers["Set-Cookie"].should start_with(Caramel::Session::COOKIE_NAME)
  end

  it "never lets a route's CSRF setting reach a request its route did not match" do
    form = HTTP::Headers{"Content-Type" => FORM_TYPE, "Authorization" => BEARER}
    ingress_request("POST", "/nowhere", "a=1", form.dup).status.should eq(403)

    # Only DELETE /notes/:id turns CSRF off; a POST there is checked, then 405.
    ingress_request("POST", "/notes/5", "a=1", form.dup).status.should eq(403)
    ingress_request("POST", "/notes/5", "a=1", browser(FORM_TYPE)).status.should eq(405)
  end

  it "refuses a method override into a route that reads its body differently" do
    headers = browser(FORM_TYPE)
    headers["Authorization"] = BEARER
    refused = ingress_request("POST", "/notes/5", "_method=DELETE", headers)
    refused.status.should eq(405)
    refused.headers["Allow"].should eq("GET, HEAD, DELETE")
  end

  it "lets a subtype's own ingress replace its parent's, authenticator included" do
    ingress_of("IngressSpecNoteForm").summary.should eq("1 KiB")
    body = "title=Dune"
    browser_form = ingress_request("POST", "/notes/form", body, browser(FORM_TYPE))
    {browser_form.status, browser_form.body}.should eq({201, "Dune"})
    tokened = HTTP::Headers{"Content-Type" => FORM_TYPE, "Authorization" => BEARER}
    ingress_request("POST", "/notes/form", body, tokened).status.should eq(403)
  end

  it "lists a route's non-default ingress" do
    inbox = ingress_of("IngressSpecInbox")
    inbox.summary.should eq("raw, 64 bytes, csrf off, authenticate signed?")
    ingress_of("IngressSpecShowNote").summary.should eq("csrf off, authenticate token?")
    ingress_of("IngressSpecCreateBook").should eq(Caramel::Ingress::DEFAULT)
  end
end
