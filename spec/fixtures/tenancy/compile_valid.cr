require "../../../src/caramel/tenancy"

module Fixture
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field name : String
      field slug : String
      index :slug, unique: true
    end
  end

  struct Author < SugarORM::Schema
    schema "authors" do
      field id : Int64, primary: true
      tenant account : Account
      field name : String
    end
  end

  struct Book < SugarORM::Schema
    schema "books" do
      field id : Int64, primary: true
      tenant account : Account
      field isbn : String
      belongs_to author : Author
      timestamps
      index :isbn, unique: true
    end
  end

  class AccountChangeset < SugarORM::Changeset(Account)
    param name : String
    param slug : String

    def validate(cs)
      cs.validate_tenant_slug(:slug)
    end
  end

  class Shelf < Caramel::View
    Caramel.resource_paths :books, :book

    private def blueprint
      h1 { tenant.name }
      a(href: tenant_path("/")) { "Home" }
      a(href: books_path) { "Books" }
    end
  end

  abstract struct Base < Caramel::Action
    Caramel.resource_paths :books, :book
  end

  struct Home < Base
    contract do
    end

    def handle(contract : Contract)
      page "Home", "<p>Home</p>"
    end
  end

  struct Books < Base
    contract do
    end

    def handle(contract : Contract)
      page tenant.name, Shelf.new
    end
  end

  struct Shown < Base
    contract do
      field id : Int64
    end

    def handle(contract : Contract)
      book = Book.query.preload(:account).preload(:author).find(contract.id)
      page book.try(&.isbn) || "none", "<p>#{book_path(contract.id)}</p>"
    end
  end

  struct Log < Caramel::ColdBrew::Job
    param note : String

    def perform
      Caramel::Tenancy.current?.try(&.slug)
    end
  end

  Caramel::Router.draw do
    get "/", Home
    tenant Account, by: :slug do
      get "/", Books
      get "/books", Books
      get "/books/:id", Shown
    end
  end
end

csrf = Caramel::CSRF.new("s" * 64, "https://fixture.caramel")
app = Caramel::Application.new(Fixture::AppRouter.new, csrf)
app.handle(HTTP::Request.new("GET", "/acme/books", HTTP::Headers{"Host" => "fixture.caramel"}))
account = Fixture::Account.new(id: 1_i64, name: "Acme", slug: "acme")
Caramel::Tenancy.with(account) do
  Fixture::Book.create(isbn: "1", author_id: 1_i64)
  Fixture::Book.query.where(isbn: "1").count
  Fixture::Book.query.first.try(&.update(isbn: "2"))
  Fixture::Book.query.first.try(&.delete)
  Fixture::Author.query.preload(:account).to_a
  Fixture::Log.enqueue(note: "x")
  Caramel::Cache.write("k", "v")
  Caramel::ColdBrew.publish("news", "hi")
end
Caramel::Tenancy.without { Fixture::Book.query.delete_all }
Caramel::Tenancy.each { |each_account| each_account.slug }
Fixture::AccountChangeset.new(name: "Acme", slug: "acme").valid?
puts SugarORM::Catalog.to_json(SugarORM::Catalog.declared)
