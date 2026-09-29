require "spec"
require "file_utils"
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

struct CorrettoSpecApiCreate < CorrettoSpecAction
  contract do
    field title : String
    field copies : Int32
  end

  def handle(contract : Contract)
    json({title: contract.title, copies: contract.copies}, 201)
  end
end

# Stores its upload where a spec points the application's storage.
struct CorrettoSpecUpload < CorrettoSpecAction
  contract do
    field caption : String
    field cover : Caramel::UploadedFile
  end

  def handle(contract : Contract)
    cover = contract.cover
    FileUtils.cp(cover.path, File.join(Corretto.tmpdir, cover.filename.not_nil!))
    Caramel::Response.new(201, "#{contract.caption}: #{cover.filename} #{cover.content_type} #{cover.size}")
  end
end

struct CorrettoSpecHook < CorrettoSpecAction
  ingress body: :raw, limit: 1.kilobyte, csrf: false, authenticate: :signed?

  contract do
  end

  def handle(contract : Contract)
    Caramel::Response.new(202, String.new(raw_body))
  end

  private def signed? : Bool
    request.headers["X-Signature"]? == "valid"
  end
end

module CorrettoSpecApp
  Caramel::Router.draw do
    post "/api/notes", CorrettoSpecApiCreate
    post "/covers", CorrettoSpecUpload
    post "/hooks", CorrettoSpecHook
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

  it "sends JSON, multipart uploads and raw bodies with the same cookies and CSRF" do
    client = corretto_spec_client
    json = {"Accept" => "application/json"}
    created = client.post("/api/notes", json: {title: "Tea", copies: 2}, headers: json)
    created.should have_status(201)
    JSON.parse(created.body).should eq(JSON.parse(%({"title": "Tea", "copies": 2})))
    client.post("/api/notes", json: {title: "Tea", copies: "2"}, headers: json).body.should contain("must be a JSON number")
    client.post("/api/notes", json: {title: "Tea", copies: 2}, headers: json.merge({"X-CSRF-Token" => "forged"})).should have_status(403)

    uploaded = client.post("/covers", params: {"caption" => "Front"}, files: {"cover" => Corretto::Upload.new("png bytes", "cover.png", "image/png")})
    uploaded.should have_status(201)
    uploaded.body.should eq("Front: cover.png image/png 9")
    stored = File.join(Corretto.tmpdir, "cover.png")
    File.read(stored).should eq("png bytes")
    fixture = Corretto.upload(__FILE__, "text/plain", filename: "spec.cr")
    client.post("/covers", params: {"caption" => "Source"}, files: {"cover" => fixture}).body.should eq("Source: spec.cr text/plain #{File.size(__FILE__)}")
    directory = Corretto.tmpdir
    Corretto.clean_tmpdir
    Dir.exists?(directory).should be_false
    Corretto.tmpdir.should_not eq(directory)
    Corretto.clean_tmpdir

    signed = client.post("/hooks", body: %({"id":1}), headers: {"Content-Type" => "application/json", "X-Signature" => "valid"})
    signed.should have_status(202)
    signed.body.should eq(%({"id":1}))
    client.post("/hooks", body: Bytes[0, 255], headers: {"X-Signature" => "valid"}).body.to_slice.should eq(Bytes[0, 255])
    client.post("/hooks", body: "x", headers: {"X-Signature" => "forged"}).should have_status(401)

    expect_raises(ArgumentError, "Send one body") { client.post("/api/notes", json: {title: "Tea"}, params: {"copies" => 1}) }
    expect_raises(ArgumentError, "GET sends params") { client.get("/", json: {page: 1}) }
    expect_raises(ArgumentError, "GET sends params") { client.get("/", files: {"cover" => fixture}) }
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
