require "spec"
require "../../src/caramel/corretto"
require "../fixtures/app/views/greetings/show"
require "../fixtures/app/actions/greetings"
require "../fixtures/app/actions/greetings/show"

abstract struct ActionSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    title = Caramel::HTML.escape(title_for(page))
    head = "<head><title>#{title}</title></head>"
    "<!DOCTYPE html><html>#{head}<body>#{page.body}</body></html>"
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
    first = Caramel::Partial.new("#a", "<p>A</p>")
    second = Caramel::Partial.new("#b", "<p>B</p>", "outerHTML")
    partials([first, second])
  end
end

struct ActionSpecMorph < ActionSpecAction
  contract do
  end

  def handle(contract : Contract)
    morph "#panel", with: "<p>x</p>"
  end
end

struct ActionSpecMarkup < ActionSpecAction
  contract do
  end

  def handle(contract : Contract)
    morph "#panel", with: markup { span(class: %(a"b)) { "<#{guest_name}>" } }
  end

  private def guest_name : String
    "Tom & Jerry"
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

# A changeset's errors, which arrive after the contract has passed.
struct ActionSpecRejected < ActionSpecAction
  contract do
  end

  def handle(contract : Contract)
    render_errors({"title" => ["can't be blank"], "_base" => ["<b>Closed</b>"]})
  end
end

module ActionSpecApp
  Caramel::Router.draw do
    get "/rejected", ActionSpecRejected
    get "/items/:id", ActionSpecShow
    get "/pass", ActionSpecPass
    post "/items", ActionSpecCreate
    get "/parts", ActionSpecParts
    get "/morph", ActionSpecMorph
    get "/markup", ActionSpecMarkup
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

private def post(body : String,
                 headers = HTTP::Headers.new,
                 token : String? = ACTION_SPEC_CSRF.issue) : Caramel::Response
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
  it "answers errors found after the contract as JSON, an escaped page or MRDP text" do
    json = get("/rejected", HTTP::Headers{"Accept" => "application/json"})
    json.status.should eq(422)
    JSON.parse(json.body).should eq(JSON.parse(<<-JSON))
      {"errors": {"title": ["can't be blank"], "_base": ["<b>Closed</b>"]}}
      JSON

    page = get("/rejected")
    page.status.should eq(422)
    page.should have_html {
      li {
        code { "title" }
        plain ": can't be blank"
      }
    }
    page.should have_html { li { "_base: <b>Closed</b>" } }

    text = get("/rejected", HTTP::Headers{"Accept" => "*/*"})
    text.status.should eq(422)
    text.headers["Content-Type"].should eq("text/plain; charset=utf-8")
    text.body.should eq(<<-MRDP + "\n")
      ERR INVALID:422 at GET /rejected
      FIELD title: can't be blank
      FIELD _base: <b>Closed</b>
      MRDP
  end

  it "negotiates a full page, an htmx fragment or JSON from one result" do
    full = get("/items/5")
    full.status.should eq(200)
    full.should render_page("Item")
    full.should have_html { p { "item 5" } }
    full.headers["Vary"].should eq("Accept, HX-Request, HX-Request-Type")
    full.headers["Set-Cookie"].should start_with(Caramel::CSRF::COOKIE_NAME)

    partial = get("/items/5", HTTP::Headers{"HX-Request-Type" => "partial"})
    partial.body.should eq("<title>Item</title><p>item 5</p>")
    partial.should_not render_page("Item")
    partial.should have_html { title { "Item" } }
    partial.should have_html { p { "item 5" } }

    json = get("/items/5", HTTP::Headers{"Accept" => "application/json"})
    json.headers["Content-Type"].should eq("application/json")
    json.headers["Vary"].should eq("Accept, HX-Request, HX-Request-Type")
    json.headers.has_key?("Set-Cookie").should be_false
    JSON.parse(json.body).should eq(JSON.parse(%({"id":5,"name":"Item 5"})))

    htmx_json = HTTP::Headers{"Accept" => "application/json", "HX-Request" => "true"}
    htmx = get("/items/5", htmx_json)
    htmx.should render_page("Item")
    prefers_json = HTTP::Headers{"Accept" => "text/html;q=0.9, application/json"}
    get("/items/5", prefers_json).headers["Content-Type"].should eq("application/json")
    prefers_html = HTTP::Headers{"Accept" => "text/html, application/json;q=0.5"}
    get("/items/5", prefers_html).should render_page("Item")
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
    html.should have_html {
      li {
        code { "seats" }
        plain ": must be at least 1"
      }
    }
    html.headers["Content-Type"].should eq("text/html; charset=utf-8")

    json = post("seats=0", HTTP::Headers{"Accept" => "application/json"})
    json.status.should eq(422)
    json.body.should eq(%({"errors":{"seats":["must be at least 1"]}}))

    text = post("seats=0&extra=1", HTTP::Headers{"Accept" => "*/*"})
    text.status.should eq(422)
    text.headers["Content-Type"].should eq("text/plain; charset=utf-8")
    text.body.should eq(<<-MRDP + "\n")
      ERR CONTRACT_INVALID:422 at POST /items
      FIELD seats: must be at least 1
      FIELD _base: Unknown field: extra
      MRDP
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
    first = %(<hx-partial hx-target="#a" hx-swap="innerMorph"><p>A</p></hx-partial>)
    second = %(<hx-partial hx-target="#b" hx-swap="outerHTML"><p>B</p></hx-partial>)
    response = get("/parts")
    response.body.should eq(first + second)
    response.should render_partial("#a", swap: "innerMorph") { p { "A" } }
    response.should render_partial("#b", swap: "outerHTML") { p { "B" } }
    response.should have_html(count: 2) { element("hx-partial") }
  end

  it "morphs one target" do
    morphed = %(<hx-partial hx-target="#panel" hx-swap="innerMorph"><p>x</p></hx-partial>)
    response = get("/morph")
    response.body.should eq(morphed)
    response.should render_partial("#panel", swap: "innerMorph") { p { "x" } }
  end

  it "builds a small fragment inline with a view's escaping and the action's own methods" do
    get("/markup").body.should contain(%(<span class="a&quot;b">&lt;Tom &amp; Jerry&gt;</span>))
  end

  it "renders a view page with escaped input and a nested view" do
    response = get("/greetings/%3CAda%3E", HTTP::Headers{"HX-Request-Type" => "partial"})
    response.body.should end_with("<p>Hello, &lt;Ada&gt;</p><footer>Caramel</footer>")
    response.should have_html { p { "Hello, <Ada>" } }
    response.should have_html { footer { "Caramel" } }
  end

  it "wraps pages of actions without a layout in a minimal escaped document" do
    head = %(<head><meta charset="utf-8"><title>Tom &amp; Jerry</title></head>)
    document = %(<!DOCTYPE html><html lang="en">#{head}<body><p>bare</p></body></html>)
    get("/bare").body.should eq(document)

    partial = HTTP::Headers{"HX-Request-Type" => "partial"}
    fragment = "<title>Tom &amp; Jerry</title><p>bare</p>"
    get("/bare", partial).body.should eq(fragment)
  end
end
