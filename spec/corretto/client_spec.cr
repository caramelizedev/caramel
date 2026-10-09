require "spec"
require "file_utils"
require "../../src/caramel/corretto"

abstract struct CorrettoSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    title = Caramel::HTML.escape(title_for(page))
    head = %(<head><title>#{title}</title></head>)
    %(<!DOCTYPE html><html>#{head}<body>#{page.body}</body></html>)
  end
end

struct CorrettoSpecHome < CorrettoSpecAction
  contract do
  end

  def handle(contract : Contract)
    reader = Caramel::HTML.escape(session["user_id"]? || "guest")
    page "Tom & Jerry's shelf", "<p>Reader #{reader}</p>"
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
    item = Caramel::HTML.escape("#{contract.title} ×#{contract.copies}")
    morph("#note-list", item, swap: "beforeend")
  end
end

struct CorrettoSpecTags < CorrettoSpecAction
  contract do
    field ids : Array(Int64), max: 5
  end

  def handle(contract : Contract)
    Caramel::Response.new(200, contract.ids.join(","))
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
    summary = "#{cover.filename} #{cover.content_type} #{cover.size}"
    Caramel::Response.new(201, "#{contract.caption}: #{summary}")
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
    post "/tags", CorrettoSpecTags
    get "/tags", CorrettoSpecTags
    get "/notes/:id", CorrettoSpecShow
    patch "/notes/:id", CorrettoSpecMove
  end
end

private record CorrettoSpecUser, id : Int64

private def corretto_spec_client : Corretto::Client
  router = CorrettoSpecApp::AppRouter.new
  csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
  Corretto::Client.new(Caramel::Application.new(router, csrf))
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

    milk = {"title" => "<b>Milk</b>", "copies" => 2}
    created = client.post("/notes", headers: {"HX-Request" => "true"}, params: milk)
    created.should have_status(200)
    created.should render_partial("#note-list", swap: "beforeend")
    created.should_not render_partial("#note-list", swap: "innerMorph")
    created.should_not render_page("Milk")
    created.should have_html {
      element("hx-partial", hx_target: "#note-list") { "<b>Milk</b> ×2" }
    }

    forged = {"X-CSRF-Token" => "forged"}
    forged_note = {"title" => "Forged", "copies" => 1}
    client.post("/notes", headers: forged, params: forged_note).should have_status(403)
    cross_site = {"Origin" => "https://evil.example"}
    cross_site_note = {"title" => "Cross-site", "copies" => 1}
    client.post("/notes", headers: cross_site, params: cross_site_note).should have_status(403)
    client.get("/", headers: {"Host" => "evil.example"}).should have_status(421)
  end

  it "signs users in, follows 303 and HX-Location redirects and collects streamed bodies" do
    client = corretto_spec_client
    client.sign_in(CorrettoSpecUser.new(42))
    client.get("/").should have_html { p { "Reader 42" } }

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
    client.get("/").should have_html { p { "Reader 42" } }
  end

  it "sends JSON with the same cookies and CSRF as a form" do
    client = corretto_spec_client
    accept = {"Accept" => "application/json"}
    forged = accept.merge({"X-CSRF-Token" => "forged"})
    note = {title: "Tea", copies: 2}

    created = client.post("/api/notes", json: note, headers: accept)
    created.should have_status(201)
    JSON.parse(created.body).should eq(JSON.parse(%({"title": "Tea", "copies": 2})))

    quoted = client.post("/api/notes", json: {title: "Tea", copies: "2"}, headers: accept)
    quoted.body.should contain("must be a JSON number")
    client.post("/api/notes", json: note, headers: forged).should have_status(403)
  end

  it "uploads files beside form params and keeps what the app stores in Corretto.tmpdir" do
    client = corretto_spec_client
    cover = {"cover" => Corretto::Upload.new("png bytes", "cover.png", "image/png")}
    uploaded = client.post("/covers", params: {"caption" => "Front"}, files: cover)
    uploaded.should have_status(201)
    uploaded.body.should eq("Front: cover.png image/png 9")
    File.read(File.join(Corretto.tmpdir, "cover.png")).should eq("png bytes")

    fixture = {"cover" => Corretto.upload(__FILE__, "text/plain", filename: "spec.cr")}
    source = client.post("/covers", params: {"caption" => "Source"}, files: fixture)
    source.body.should eq("Source: spec.cr text/plain #{File.size(__FILE__)}")

    directory = Corretto.tmpdir
    Corretto.clean_tmpdir
    Dir.exists?(directory).should be_false
    Corretto.tmpdir.should_not eq(directory)
    Corretto.clean_tmpdir
  end

  it "sends a raw body exactly as given, with the headers a webhook signs" do
    client = corretto_spec_client
    valid = {"X-Signature" => "valid"}
    json = valid.merge({"Content-Type" => "application/json"})
    delivered = client.post("/hooks", body: %({"id":1}), headers: json)
    delivered.should have_status(202)
    delivered.body.should eq(%({"id":1}))

    binary = client.post("/hooks", body: Bytes[0, 255], headers: valid)
    binary.body.to_slice.should eq(Bytes[0, 255])
    forged = client.post("/hooks", body: "x", headers: {"X-Signature" => "forged"})
    forged.should have_status(401)
  end

  it "sends an Array param as one key per item" do
    client = corretto_spec_client
    client.post("/tags", params: {"ids" => [1, 2]}).body.should eq("1,2")
    client.get("/tags", params: {"ids" => [3, 4]}).body.should eq("3,4")
    upload = Corretto::Upload.new("x", "a.txt", "text/plain")
    sent = client.post("/tags", params: {"ids" => [5, 6]}, files: {"extra" => upload})
    sent.should have_status(422)
  end

  it "refuses a request with two bodies, or a GET with any body" do
    client = corretto_spec_client
    fixture = Corretto::Upload.new("png bytes", "cover.png", "image/png")
    expect_raises(ArgumentError, "Send one body") do
      client.post("/api/notes", json: {title: "Tea"}, params: {"copies" => 1})
    end
    expect_raises(ArgumentError, "GET sends params") { client.get("/", json: {page: 1}) }
    expect_raises(ArgumentError, "GET sends params") do
      client.get("/", files: {"cover" => fixture})
    end
  end

  it "explains failed expectations with the relevant response" do
    client = corretto_spec_client
    home = client.get("/")
    status = /Expected status 201, got 200\nResponse status 200\n.*Body: <!DOCTYPE html>/m
    expect_raises(Spec::AssertionFailed, status) { home.should have_status(201) }
    titled = /Expected a full HTML page titled "Kitchen"; got "Tom & Jerry's shelf"/
    expect_raises(Spec::AssertionFailed, titled) { home.should render_page("Kitchen") }
    redirected = /Expected a redirect \(Location or HX-Location\) to \/notes\/1/
    expect_raises(Spec::AssertionFailed, redirected) { home.should redirect_to("/notes/1") }
    header = /Expected header HX-Location: \/notes\/1/
    expect_raises(Spec::AssertionFailed, header) do
      home.should have_header("HX-Location", "/notes/1")
    end

    tea = {"title" => "Tea", "copies" => 1}
    created = client.post("/notes", headers: {"HX-Request" => "true"}, params: tea)
    target = "#shelf swapped with innerMorph"
    partial = /Expected an <hx-partial> for #{target}; found #note-list \(beforeend\)/
    expect_raises(Spec::AssertionFailed, partial) do
      created.should render_partial("#shelf", swap: "innerMorph")
    end
    expect_raises(Spec::AssertionFailed, /got no <title>/) { created.should render_page("Tea") }
  end
end
