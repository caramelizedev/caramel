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

  # Every page, central and tenant, is for members; the tenant routes inherit
  # the authenticator.
  abstract struct Base < Caramel::Action
    Caramel.resource_paths :books, :book
    ingress authenticate: :member?

    private def member? : Bool
      true
    end
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

# What libraries outside the framework use of tenancy; each declaration's comment says so.
# A tenanted schema names its tenant's column in SUGAR_TENANT, and the tenant has none.
{% unless Fixture::Book.has_constant?(:SUGAR_TENANT) &&
            Fixture::Book.constant(:SUGAR_TENANT) == "account_id" %}
  {% raise "Fixture::Book::SUGAR_TENANT must be \"account_id\"" %}
{% end %}
{% if Fixture::Account.has_constant?(:SUGAR_TENANT) %}
  {% raise "Fixture::Account has no tenant, so it must have no SUGAR_TENANT" %}
{% end %}
# Caramel::Tenancy.find takes the tenant's primary key as *id* and returns the tenant or nil.
{% begin %}
  {% finds = Caramel::Tenancy.class.methods.select { |method| method.name == "find" } %}
  {% signatures = finds.map { |method| "#{method.args.splat} : #{method.return_type}" } %}
  {% by_id = "id : ::Fixture::Account::PrimaryKey : ::SugarORM::Tenancy::Tenant | ::Nil" %}
  {% unless signatures.includes?(by_id) %}
    {% raise "Caramel::Tenancy.find must be declared as (#{by_id.id}), not as #{signatures}" %}
  {% end %}
{% end %}
Caramel::Tenancy.find(id: account.id).try(&.slug)
