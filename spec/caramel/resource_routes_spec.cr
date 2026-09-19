require "spec"
require "../../src/caramel"

private class RoutedBooksController < Caramel::Controller
  {% for action in %w(index new create) %}
    def {{action.id}} : Caramel::Response
      Caramel::Response.new(body: {{action}})
    end
  {% end %}
  {% for action in %w(show edit update destroy change) %}
    def {{action.id}}(id : Int64) : Caramel::Response
      Caramel::Response.new(body: "#{{{action}}}:#{id}")
    end
  {% end %}
end

private module BookPaths
  Caramel.resource_paths :books, :book
  extend self
end

describe "resource routing" do
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

  it "binds the complete resource to typed controller methods" do
    router = Caramel::Router.new
    csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
    router.resources(:books, RoutedBooksController, csrf)
    {
      {"GET", "/books"}         => "index",
      {"GET", "/books/new"}     => "new",
      {"POST", "/books"}        => "create",
      {"GET", "/books/42"}      => "show:42",
      {"GET", "/books/42/edit"} => "edit:42",
      {"PUT", "/books/42"}      => "update:42",
      {"PATCH", "/books/42"}    => "update:42",
      {"DELETE", "/books/42"}   => "destroy:42",
      {"POST", "/books/42"}     => "change:42",
    }.each do |route, body|
      router.call(HTTP::Request.new(route[0], route[1])).body.should eq(body)
    end
    ["nope", "0", "-1", "9223372036854775808", "1_000"].each do |id|
      router.call(HTTP::Request.new("GET", "/books/#{id}")).status.should eq(404)
    end
    router.call(HTTP::Request.new("HEAD", "/books/42")).body.should eq("")
  end

  it "generates unambiguous typed paths and lists the registered routes" do
    BookPaths.books_path.should eq("/books")
    BookPaths.book_path(42_i64).should eq("/books/42")
    BookPaths.new_book_path.should eq("/books/new")
    BookPaths.edit_book_path(42_i64).should eq("/books/42/edit")
    expect_raises(ArgumentError) { BookPaths.book_path(0_i64) }
    router = Caramel::Router.new
    router.get("/") { |_, _| Caramel::Response.new }
    router.routes.should eq([{"GET", "/"}])
  end
end
