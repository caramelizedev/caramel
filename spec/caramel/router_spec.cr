require "spec"
require "../../src/caramel"

abstract struct RouterSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

struct TeamNew < RouterSpecAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "new")
  end
end

struct TeamShow < RouterSpecAction
  contract do
    field team_id : Int64, min: 1
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "show:#{contract.team_id}")
  end
end

struct TeamUpdate < RouterSpecAction
  contract do
    field team_id : Int64, min: 1
    field name : String?
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "update:#{contract.team_id}:#{contract.name}")
  end
end

struct TeamMembers < RouterSpecAction
  contract do
    field team_id : String
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "members:#{contract.team_id}")
  end
end

struct FileShow < RouterSpecAction
  contract do
    field name : String
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: contract.name)
  end
end

module RouterSpecApp
  Caramel::Router.draw do
    get "/teams/new", TeamNew
    get "/teams/:team_id", TeamShow
    patch "/teams/:team_id", TeamUpdate
    get "/teams/:team_id/members", TeamMembers
    get "/files/:name", FileShow
  end
end

private module BookPaths
  Caramel.resource_paths :books, :book
  extend self
end

private def route(method : String, path : String, body : String? = nil) : Caramel::Response
  headers = HTTP::Headers.new
  headers["Content-Type"] = "application/x-www-form-urlencoded" if body
  request = HTTP::Request.new(method, path, headers, body)
  csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
  context = Caramel::RequestContext.new(request, csrf, Caramel::Session.new(csrf.derive_key("session")), Caramel::RequestInput.read(request))
  RouterSpecApp::AppRouter.new.dispatch(context)
end

describe Caramel::Router do
  it "prefers static segments and binds typed parameters" do
    route("GET", "/teams/new").body.should eq("new")
    route("GET", "/teams/7").body.should eq("show:7")
  end

  it "backtracks from a static segment to a parameter route" do
    route("GET", "/teams/new/members").body.should eq("members:new")
  end

  it "answers 404 for unknown, empty-parameter and overlong paths" do
    route("GET", "/missing").status.should eq(404)
    route("GET", "/teams/").status.should eq(404)
    route("GET", "/" + (["a"] * 33).join('/')).status.should eq(404)
  end

  it "answers 405 with every allowed method" do
    response = route("POST", "/teams/7")
    response.status.should eq(405)
    response.headers["Allow"].should eq("GET, HEAD, PATCH")
  end

  it "supports HEAD without sending a response body" do
    response = route("HEAD", "/teams/42")
    response.status.should eq(200)
    response.body.should eq("")
    response.headers["Content-Length"].should eq("7")
  end

  it "rejects malformed and encoded-separator paths" do
    ["%zz", "one%2ftwo", "%01", "%0a", "%0d%0aHeader:%20bad", "%7f"].each do |value|
      route("GET", "/files/#{value}").status.should eq(400)
    end
  end

  it "decodes parameter segments" do
    route("GET", "/files/a%20b").body.should eq("a b")
  end

  it "treats unparsable or out-of-range IDs as missing resources" do
    ["nope", "0", "-1", "9223372036854775808", "1_000"].each do |id|
      route("GET", "/teams/#{id}").status.should eq(404)
    end
  end

  it "dispatches a POST method override to its route" do
    route("POST", "/teams/7", "_method=PATCH&name=Owls").body.should eq("update:7:Owls")
  end

  it "matches routes, including backtracking and method masks, without heap allocation" do
    tree = RouterSpecApp::AppRouter::TREE
    paths = {"/teams/new", "/teams/7", "/teams/new/members", "/files/a%20b", "/missing", "/"}
    match = ->(path : String) do
      segments = Caramel::Router::Segments.parse(path).not_nil!
      tree.match(path, segments, "GET")
      tree.match(path, segments, "POST")
    end
    paths.each { |path| match.call(path) }
    before = GC.stats.total_bytes
    100.times { paths.each { |path| match.call(path) } }
    (GC.stats.total_bytes - before).should eq(0)
    tree.match("/teams/new/members", Caramel::Router::Segments.parse("/teams/new/members").not_nil!, "GET")[0].should eq(3)
  end

  it "finds a request's route and ingress by its own method, before any body, without heap allocation" do
    router = RouterSpecApp::AppRouter.new
    requests = [{"GET", "/teams/new"}, {"GET", "/teams/7"}, {"HEAD", "/teams/7"}, {"POST", "/teams/7"}, {"GET", "/missing"}, {"GET", "/%zz"}].map do |(method, path)|
      HTTP::Request.new(method, path)
    end
    requests.each { |request| router.match(request) }
    before = GC.stats.total_bytes
    100.times { requests.each { |request| router.match(request) } }
    (GC.stats.total_bytes - before).should eq(0)
    requests.map { |request| router.match(request).index }.should eq([0, 1, 1, -1, -1, -1])
    router.match(requests[3]).mask.should eq(Caramel::Router.method_bit("GET") | Caramel::Router.method_bit("PATCH"))
    router.match(requests[5]).segments.should be_nil
    requests.each { |request| router.match(request).ingress.should eq(Caramel::Ingress::DEFAULT) }
  end

  it "lists routes with their contract summaries" do
    RouterSpecApp::AppRouter.routes.should eq([
      Caramel::Router::Entry.new("GET", "/teams/new", "TeamNew", ""),
      Caramel::Router::Entry.new("GET", "/teams/:team_id", "TeamShow", "team_id:Int64(min=1)"),
      Caramel::Router::Entry.new("PATCH", "/teams/:team_id", "TeamUpdate", "team_id:Int64(min=1) name:String?"),
      Caramel::Router::Entry.new("GET", "/teams/:team_id/members", "TeamMembers", "team_id:String"),
      Caramel::Router::Entry.new("GET", "/files/:name", "FileShow", "name:String"),
    ])
  end

  it "generates unambiguous typed resource paths" do
    BookPaths.books_path.should eq("/books")
    BookPaths.book_path(42_i64).should eq("/books/42")
    BookPaths.new_book_path.should eq("/books/new")
    BookPaths.edit_book_path(42_i64).should eq("/books/42/edit")
    expect_raises(ArgumentError) { BookPaths.book_path(0_i64) }
  end
end
