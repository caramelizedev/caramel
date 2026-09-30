require "spec"
require "../../src/caramel/response"

describe Caramel::Response do
  it "varies full and partial HTML responses on the htmx 4 request type" do
    request = HTTP::Request.new("GET", "/", HTTP::Headers{"HX-Request-Type" => "partial"})
    full = "<html>full</html>"
    partial = "<main>partial</main>"
    response = Caramel::Response.html(request, full: full, partial: partial, status: 422)
    response.body.should eq(partial)
    response.status.should eq(422)
    response.headers["Vary"].should eq("HX-Request-Type")
    request.headers["HX-Request-Type"] = "full"
    Caramel::Response.html(request, full: "full", partial: "partial").body.should eq("full")
  end

  it "only redirects to local paths" do
    Caramel::Response.redirect("/books?created=1").status.should eq(303)
    unsafe = [
      "https://evil.example",
      "//evil.example",
      "/\\evil.example",
      "/bad\r\nHeader: value",
    ]
    unsafe.each do |path|
      expect_raises(ArgumentError) { Caramel::Response.redirect(path) }
    end
  end

  it "uses htmx navigation for enhanced submissions and a 303 for native forms" do
    native = HTTP::Request.new("POST", "/books")
    response = Caramel::Response.navigate(native, "/books/42")
    response.status.should eq(303)
    response.headers["Location"].should eq("/books/42")
    htmx = HTTP::Headers{"HX-Request" => "true", "HX-Request-Type" => "partial"}
    enhanced = HTTP::Request.new("POST", "/books", htmx)
    response = Caramel::Response.navigate(enhanced, "/books/42")
    response.status.should eq(200)
    response.headers["HX-Location"].should eq("/books/42")
    response.headers["Vary"].should eq("HX-Request")
    response.headers.has_key?("Location").should be_false
    expect_raises(ArgumentError) { Caramel::Response.navigate(enhanced, "//other.caramel") }
  end

  it "redirects to other sites only for absolute http and https URLs without credentials" do
    native = HTTP::Request.new("GET", "/go")
    away = Caramel::Response.redirect_external(native, "https://example.com/a?b=1")
    away.status.should eq(302)
    away.headers["Location"].should eq("https://example.com/a?b=1")
    enhanced = HTTP::Request.new("GET", "/go", HTTP::Headers{"HX-Request" => "true"})
    swapped = Caramel::Response.redirect_external(enhanced, "https://example.com/a")
    swapped.status.should eq(200)
    swapped.headers["HX-Redirect"].should eq("https://example.com/a")
    swapped.headers.has_key?("Location").should be_false
    refused = [
      "/local", "//example.com", "javascript:alert(1)", "ftp://example.com/x", "https://",
      "https://example.com/\r\nX: y", "https://user:pass@example.com/",
      "https://trusted.example@evil.example/", "https://example.com/a b", "https:\\\\example.com",
    ]
    refused.each do |url|
      expect_raises(ArgumentError) { Caramel::Response.redirect_external(native, url) }
    end
    expect_raises(ArgumentError) do
      Caramel::Response.redirect_external(native, "https://example.com", 200)
    end
  end
end
