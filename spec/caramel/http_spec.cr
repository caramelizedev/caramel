require "spec"
require "../../src/caramel/response"

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

  it "uses htmx navigation for enhanced submissions and a 303 for native forms" do
    native = HTTP::Request.new("POST", "/books")
    response = Caramel::Response.navigate(native, "/books/42")
    response.status.should eq(303)
    response.headers["Location"].should eq("/books/42")
    enhanced = HTTP::Request.new("POST", "/books", HTTP::Headers{"HX-Request" => "true", "HX-Request-Type" => "partial"})
    response = Caramel::Response.navigate(enhanced, "/books/42")
    response.status.should eq(200)
    response.headers["HX-Location"].should eq("/books/42")
    response.headers["Vary"].should eq("HX-Request")
    response.headers.has_key?("Location").should be_false
    expect_raises(ArgumentError) { Caramel::Response.navigate(enhanced, "//other.caramel") }
  end
end
