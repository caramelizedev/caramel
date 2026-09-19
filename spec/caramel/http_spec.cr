require "spec"
require "../../src/caramel/router"

describe Caramel::Router do
  it "extracts route parameters and keeps methods distinct" do
    router = Caramel::Router.new
    router.get("/books/:id") { |request, params| Caramel::Response.new(body: params["id"]) }
    router.call(HTTP::Request.new("GET", "/books/42")).body.should eq("42")
    response = router.call(HTTP::Request.new("POST", "/books/42"))
    response.status.should eq(405)
    response.headers["Allow"].should eq("GET, HEAD")
    router.call(HTTP::Request.new("GET", "/missing")).status.should eq(404)
  end

  it "supports HEAD without sending a response body" do
    router = Caramel::Router.new
    router.get("/") { |_, _| Caramel::Response.new(body: "hello") }
    response = router.call(HTTP::Request.new("HEAD", "/"))
    response.status.should eq(200)
    response.body.should eq("")
    response.headers["Content-Length"].should eq("5")
  end

  it "rejects malformed and encoded-separator route parameters" do
    router = Caramel::Router.new
    router.get("/books/:id") { |_, params| Caramel::Response.new(body: params["id"]) }
    router.call(HTTP::Request.new("GET", "/books/%zz")).status.should eq(400)
    router.call(HTTP::Request.new("GET", "/books/one%2ftwo")).status.should eq(400)
    ["%01", "%0a", "%0d%0aHeader:%20bad", "%7f"].each do |value|
      router.call(HTTP::Request.new("GET", "/books/#{value}")).status.should eq(400)
    end
  end
end

describe Caramel::Response do
  it "varies full and partial HTML responses on the htmx 4 request type" do
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"HX-Request-Type" => "partial"})
    response = Caramel::Response.html(request, full: "<html>full</html>", partial: "<main>partial</main>", status: 422)
    response.body.should eq("<main>partial</main>")
    response.status.should eq(422)
    response.headers["Vary"].should eq("HX-Request-Type")
    request.headers["HX-Request-Type"] = "full"
    Caramel::Response.html(request, full: "full", partial: "partial").body.should eq("full")
  end

  it "only redirects to local paths" do
    Caramel::Response.redirect("/books?created=1").status.should eq(303)
    ["https://evil.example", "//evil.example", "/\\evil.example", "/bad\r\nHeader: value"].each do |path|
      expect_raises(ArgumentError) { Caramel::Response.redirect(path) }
    end
  end
end
