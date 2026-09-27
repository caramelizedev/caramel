require "spec"
require "../../src/caramel"
require "../fixtures/app/actions/greetings"
require "../fixtures/app/actions/greetings/show"

abstract struct ActionSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    "<!DOCTYPE html><html><head><title>#{Caramel::HTML.escape(title_for(page))}</title></head><body>#{page.body}</body></html>"
  end
end

struct ActionSpecShow < ActionSpecAction
  contract do
    field id : Int64, min: 1
  end

  def handle(contract : Contract)
    return not_found("Item not found") if contract.id == 404
    {id: contract.id, name: "Item #{contract.id}"}
  end

  def render(result)
    page "Item", "<p>item #{result[:id]}</p>"
  end
end

struct ActionSpecPass < ActionSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(418, "teapot")
  end
end

struct ActionSpecCreate < ActionSpecAction
  contract do
    field seats : Int32, min: 1
  end

  def handle(contract : Contract)
    self.status = 201
    {seats: contract.seats}
  end

  def render(result)
    redirect_to("/items/#{result[:seats]}")
  end
end

struct ActionSpecParts < ActionSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    partials([Caramel::Partial.new("#a", "<p>A</p>"), Caramel::Partial.new("#b", "<p>B</p>", "outerHTML")])
  end
end

struct ActionSpecMorph < ActionSpecAction
  contract do
  end

  def handle(contract : Contract)
    morph "#panel", with: "<p>x</p>"
  end
end

# Inherits Caramel::Action directly, with no layout of its own.
struct ActionSpecBare < Caramel::Action
  contract do
  end

  def handle(contract : Contract)
    page "Tom & Jerry", "<p>bare</p>"
  end
end

module ActionSpecApp
  Caramel::Router.draw do
    get "/items/:id", ActionSpecShow
    get "/pass", ActionSpecPass
    post "/items", ActionSpecCreate
    get "/parts", ActionSpecParts
    get "/morph", ActionSpecMorph
    get "/bare", ActionSpecBare
    get "/greetings/:name", Greetings::Show
  end
end

private ACTION_SPEC_CSRF = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
private ACTION_SPEC_APP  = Caramel::Application.new(ActionSpecApp::AppRouter.new, ACTION_SPEC_CSRF)

private def get(path : String, headers = HTTP::Headers.new) : Caramel::Response
  headers["Host"] = "bookshelf.caramel"
  ACTION_SPEC_APP.handle(HTTP::Request.new("GET", path, headers))
end

private def post(body : String, headers = HTTP::Headers.new, token : String? = ACTION_SPEC_CSRF.issue) : Caramel::Response
  headers["Host"] = "bookshelf.caramel"
  headers["Origin"] = "https://bookshelf.caramel"
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  if token
    headers["Cookie"] = "#{Caramel::CSRF::COOKIE_NAME}=#{token}"
    body = "_csrf=#{token}&#{body}" unless headers.has_key?("X-CSRF-Token")
  end
  ACTION_SPEC_APP.handle(HTTP::Request.new("POST", "/items", headers, body))
end

describe Caramel::Action do
  it "negotiates a full page, an htmx fragment or JSON from one result" do
    full = get("/items/5")
    full.status.should eq(200)
    full.body.should start_with("<!DOCTYPE html>")
    full.body.should contain("<p>item 5</p>")
    full.headers["Vary"].should eq("Accept, HX-Request, HX-Request-Type")
    full.headers["Set-Cookie"].should start_with(Caramel::CSRF::COOKIE_NAME)

    partial = get("/items/5", HTTP::Headers{"HX-Request-Type" => "partial"})
    partial.body.should eq("<title>Item</title><p>item 5</p>")

    json = get("/items/5", HTTP::Headers{"Accept" => "application/json"})
    json.headers["Content-Type"].should eq("application/json")
    json.headers["Vary"].should eq("Accept, HX-Request, HX-Request-Type")
    json.headers.has_key?("Set-Cookie").should be_false
    JSON.parse(json.body).should eq(JSON.parse(%({"id":5,"name":"Item 5"})))

    htmx = get("/items/5", HTTP::Headers{"Accept" => "application/json", "HX-Request" => "true"})
    htmx.body.should start_with("<!DOCTYPE html>")
    get("/items/5", HTTP::Headers{"Accept" => "text/html;q=0.9, application/json"}).headers["Content-Type"].should eq("application/json")
    get("/items/5", HTTP::Headers{"Accept" => "text/html, application/json;q=0.5"}).body.should start_with("<!DOCTYPE html>")
  end

  it "passes a Response from handle through unchanged" do
    response = get("/pass", HTTP::Headers{"Accept" => "application/json"})
    response.status.should eq(418)
    response.body.should eq("teapot")
    missing = get("/items/404", HTTP::Headers{"Accept" => "application/json"})
    missing.status.should eq(404)
    missing.body.should eq("Item not found")
  end

  it "renders contract failures for browsers, JSON clients and other clients" do
    html = post("seats=0", HTTP::Headers{"Accept" => "text/html"})
    html.status.should eq(422)
    html.body.should contain(%(<li><code>seats</code>: must be at least 1</li>))
    html.headers["Content-Type"].should eq("text/html; charset=utf-8")

    json = post("seats=0", HTTP::Headers{"Accept" => "application/json"})
    json.status.should eq(422)
    json.body.should eq(%({"errors":{"seats":["must be at least 1"]}}))

    text = post("seats=0&extra=1", HTTP::Headers{"Accept" => "*/*"})
    text.status.should eq(422)
    text.headers["Content-Type"].should eq("text/plain; charset=utf-8")
    text.body.should eq("ERR CONTRACT_INVALID:422 at POST /items\nFIELD seats: must be at least 1\nFIELD _base: Unknown field: extra\n")
  end

  it "requires CSRF for writes and accepts the header token" do
    post("seats=2", token: nil).status.should eq(403)
    token = ACTION_SPEC_CSRF.issue
    accepted = post("seats=2", HTTP::Headers{"X-CSRF-Token" => token}, token)
    accepted.status.should eq(303)
  end

  it "redirects browsers and returns created JSON to API clients" do
    native = post("seats=3")
    native.status.should eq(303)
    native.headers["Location"].should eq("/items/3")
    htmx = post("seats=3", HTTP::Headers{"HX-Request" => "true", "Accept" => "text/html"})
    htmx.status.should eq(200)
    htmx.headers["HX-Location"].should eq("/items/3")
    created = post("seats=3", HTTP::Headers{"Accept" => "application/json"})
    created.status.should eq(201)
    created.body.should eq(%({"seats":3}))
  end

  it "renders several targets in one response" do
    get("/parts").body.should eq(%(<hx-partial hx-target="#a" hx-swap="innerMorph"><p>A</p></hx-partial><hx-partial hx-target="#b" hx-swap="outerHTML"><p>B</p></hx-partial>))
  end

  it "morphs one target" do
    get("/morph").body.should eq(%(<hx-partial hx-target="#panel" hx-swap="innerMorph"><p>x</p></hx-partial>))
  end

  it "renders conventional views with escaped locals and trusted partial views" do
    response = get("/greetings/%3CAda%3E", HTTP::Headers{"HX-Request-Type" => "partial"})
    response.body.should end_with("<p>Hello, &lt;Ada&gt;</p><footer>Caramel</footer>")
  end

  it "wraps pages of actions without a layout in a minimal escaped document" do
    bare = get("/bare")
    bare.body.should eq(%(<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Tom &amp; Jerry</title></head><body><p>bare</p></body></html>))
    get("/bare", HTTP::Headers{"HX-Request-Type" => "partial"}).body.should eq("<title>Tom &amp; Jerry</title><p>bare</p>")
  end
end
