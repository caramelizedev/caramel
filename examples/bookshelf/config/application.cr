require "../../../src/caramel"
require "../db/migrations/*"
require "../app/models/*"
require "../app/controllers/*"

module Bookshelf
  class App
    getter application : Caramel::Application

    def initialize(db : DB::Database, secret : String, origin = "https://bookshelf.caramel")
      store = BookStore.new(db)
      csrf = Caramel::CSRF.new(secret, origin)
      router = Caramel::Router.new
      router.get("/") { |_, _| Caramel::Response.redirect("/books") }
      router.get("/health") { |_, _| Caramel::Response.new(body: "ok") }
      router.get("/books") { |request, _| BooksController.new(request, csrf, store).index }
      router.get("/books/new") { |request, _| BooksController.new(request, csrf, store).new }
      router.post("/books") { |request, _| BooksController.new(request, csrf, store).create }
      router.get("/books/:id") do |request, params|
        id = params["id"].to_i64?
        id ? BooksController.new(request, csrf, store).show(id) : Caramel::Response.new(404, "Book not found")
      end
      router.get("/books/:id/edit") do |request, params|
        id = params["id"].to_i64?
        id ? BooksController.new(request, csrf, store).edit(id) : Caramel::Response.new(404, "Book not found")
      end
      {% for method in %w(post patch put delete) %}
        router.{{method.id}}("/books/:id") do |request, params|
          id = params["id"].to_i64?
          id ? BooksController.new(request, csrf, store).change(id) : Caramel::Response.new(404, "Book not found")
        end
      {% end %}
      @application = Caramel::Application.new(router, origin, "#{__DIR__}/../public")
    end
  end
end
