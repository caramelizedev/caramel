require "spec"
require "../../src/caramel/corretto"

abstract struct CorrettoSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    %(<!DOCTYPE html><html><head><title>#{Caramel::HTML.escape(title_for(page))}</title></head><body>#{page.body}</body></html>)
  end
end

struct CorrettoSpecHome < CorrettoSpecAction
  contract do
  end

  def handle(contract : Contract)
    page "Tom & Jerry's shelf", "<p>Reader #{Caramel::HTML.escape(session["user_id"]? || "guest")}</p>"
  end
end

struct CorrettoSpecShow < CorrettoSpecAction
  contract do
    field id : Int64
  end

  def handle(contract : Contract)
    page "Note #{contract.id}", "<p>Note #{contract.id}</p>"
  end
end

struct CorrettoSpecCreate < CorrettoSpecAction
  contract do
    field title : String
    field copies : Int32
  end

  def handle(contract : Contract)
    morph("#note-list", Caramel::HTML.escape("#{contract.title} ×#{contract.copies}"), swap: "beforeend")
  end
end

struct CorrettoSpecMove < CorrettoSpecAction
  contract do
    field id : Int64
  end

  def handle(contract : Contract)
    redirect_to("/notes/#{contract.id}")
  end
end

struct CorrettoSpecEvents < CorrettoSpecAction
  contract do
  end

  def handle(contract : Contract)
    stream("text/event-stream") { |io| io << "data: one\n\n" }
  end
end

module CorrettoSpecApp
  Caramel::Router.draw do
    get "/", CorrettoSpecHome
    get "/events", CorrettoSpecEvents
    post "/notes", CorrettoSpecCreate
    get "/notes/:id", CorrettoSpecShow
    patch "/notes/:id", CorrettoSpecMove
  end
end

private record CorrettoSpecUser, id : Int64

private def corretto_spec_client : Corretto::Client
  Corretto::Client.new(Caramel::Application.new(CorrettoSpecApp::AppRouter.new, Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")))
end

describe Corretto::Client do
  it "sends in-process requests with a cookie jar, form params and automatic CSRF" do
    client = corretto_spec_client
    home = client.get("/")
    home.should have_status(200)
    home.should render_page("Tom & Jerry's shelf")
    home.should_not render_page("Kitchen")
    home.should_not render_partial("#note-list")
    client.cookies.has_key?(Caramel::CSRF::COOKIE_NAME).should be_true

    created = client.post("/notes", headers: {"HX-Request" => "true"}, params: {"title" => "<b>Milk</b>", "copies" => 2})
    created.should have_status(200)
    created.should render_partial("#note-list", swap: "beforeend")
    created.should_not render_partial("#note-list", swap: "innerMorph")
    created.should_not render_page("Milk")
    created.body.should contain("&lt;b&gt;Milk&lt;/b&gt; ×2")

    client.post("/notes", headers: {"X-CSRF-Token" => "forged"}, params: {"title" => "Forged", "copies" => 1}).should have_status(403)
    client.post("/notes", headers: {"Origin" => "https://evil.example"}, params: {"title" => "Cross-site", "copies" => 1}).should have_status(403)
    client.get("/", headers: {"Host" => "evil.example"}).should have_status(421)
  end

  it "signs users in, follows 303 and HX-Location redirects and collects streamed bodies" do
    client = corretto_spec_client
    client.sign_in(CorrettoSpecUser.new(42))
    client.get("/").body.should contain("Reader 42")

    moved = client.patch("/notes/7")
    moved.should have_status(303)
    moved.should redirect_to("/notes/7")
    moved.should have_header("Location", "/notes/7")
    moved.should_not have_header("HX-Location")
    client.follow_redirect.should render_page("Note 7")

    boosted = client.patch("/notes/8", headers: {"HX-Request" => "true"})
    boosted.should have_status(200)
    boosted.should redirect_to("/notes/8")
    boosted.should_not redirect_to("/notes/7")
    boosted.should have_header("HX-Location", "/notes/8")
    client.follow_redirect.should render_page("Note 8")
    expect_raises(Corretto::Error, "not a redirect") { client.follow_redirect }

    client.get("/events").body.should eq("data: one\n\n")
    client.get("/", params: {"utm" => "spec"}).should render_page("Tom & Jerry")
    client.get("/").body.should contain("Reader 42")
  end

  it "explains failed expectations with the relevant response" do
    client = corretto_spec_client
    home = client.get("/")
    expect_raises(Spec::AssertionFailed, /Expected status 201, got 200\nResponse status 200\n.*Body: <!DOCTYPE html>/m) { home.should have_status(201) }
    expect_raises(Spec::AssertionFailed, /Expected a full HTML page titled "Kitchen"; got "Tom & Jerry's shelf"/) { home.should render_page("Kitchen") }
    expect_raises(Spec::AssertionFailed, /Expected a redirect \(Location or HX-Location\) to \/notes\/1/) { home.should redirect_to("/notes/1") }
    expect_raises(Spec::AssertionFailed, /Expected header HX-Location: \/notes\/1/) { home.should have_header("HX-Location", "/notes/1") }
    created = client.post("/notes", headers: {"HX-Request" => "true"}, params: {"title" => "Tea", "copies" => 1})
    expect_raises(Spec::AssertionFailed, /Expected an <hx-partial> for #shelf swapped with innerMorph; found #note-list \(beforeend\)/) do
      created.should render_partial("#shelf", swap: "innerMorph")
    end
    expect_raises(Spec::AssertionFailed, /got no <title>/) { created.should render_page("Tea") }
  end
end
