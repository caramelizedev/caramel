require "spec"
require "random/secure"
require "../../../src/caramel/tenancy"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
private def owned_url(variable : String) : String
  ENV[variable]? || raise "Run scripts/check integration; no #{variable} provided"
end

# A multi-tenant application (ADR 0025) on a scratch database of its own.
# Each example runs in a transaction that is rolled back afterwards.
module TenancySpec
  ADMIN_URL   = owned_url("CARAMEL_OWNED_ADMIN_URL")
  OWNER_URL   = owned_url("CARAMEL_OWNED_SPEC_URL")
  RUNTIME_URL = owned_url("CARAMEL_OWNED_MODEL_RUNTIME_URL")
  NAME        = "caramel_tenancy_#{Random::Secure.hex(6)}"
  # What Caramel::CommandLine reads of an application.
  TITLE      = "Tenancy"
  MIGRATIONS = Caramel::ColdBrew::MIGRATIONS

  def self.seed(db : DB::Database) : Nil
  end

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
      has_many books : Book
    end
  end

  struct Book < SugarORM::Schema
    schema "books" do
      field id : Int64, primary: true
      tenant account : Account
      field title : String
      field isbn : String
      belongs_to author : Author
      index :isbn, unique: true
    end
  end

  # What Record saw: the slug of the tenant it ran in, if any.
  struct Run < SugarORM::Schema
    schema "tenancy_runs" do
      field id : Int64, primary: true
      field slug : String?
    end
  end

  class AccountChangeset < SugarORM::Changeset(Account)
    param name : String
    param slug : String

    def validate(cs)
      cs.validate_tenant_slug(:slug)
    end
  end

  # Records the tenant it runs in.
  struct Record < Caramel::ColdBrew::Job
    def perform
      Run.create!(slug: Caramel::Tenancy.current?.try(&.slug))
    end
  end

  abstract struct Action < Caramel::Action
    Caramel.resource_paths :books, :book
  end

  # Which tenant, if any, a central request sees.
  struct Home < Action
    contract do
    end

    def handle(contract : Contract)
      bound = Caramel::Tenancy.current?.try(&.slug) || "none"
      Caramel::Response.new(200, "tenant: #{bound}")
    end
  end

  struct Health < Action
    contract do
    end

    def handle(contract : Contract)
      Caramel::Response.new(200, "ok")
    end
  end

  struct Dashboard < Action
    contract do
    end

    def handle(contract : Contract)
      Caramel::Response.new(200, "#{tenant.slug} #{books_path}")
    end
  end

  struct Books < Action
    contract do
    end

    def handle(contract : Contract)
      titles = Book.query.order_by(:title).to_a.map(&.title)
      Caramel::Response.new(200, titles.join(", "))
    end
  end

  struct Shown < Action
    contract do
      field id : Int64
    end

    def handle(contract : Contract)
      book = Book.query.find(contract.id) || return not_found
      Caramel::Response.new(200, book.title)
    end
  end

  struct Streamed < Action
    contract do
    end

    def handle(contract : Contract)
      stream("text/plain; charset=utf-8") do |io|
        io << tenant.slug << ' ' << Book.query.count
      end
    end
  end

  Caramel::Router.draw do
    get "/", Home
    get "/health", Health
    tenant TenancySpec::Account, by: :slug do
      get "/", Dashboard
      get "/books", Books
      get "/books/:id", Shown
      get "/books-stream", Streamed
    end
  end

  HOST = "tenancy.caramel"
  APP  = Caramel::Application.new(AppRouter.new, Caramel::CSRF.new("s" * 64, "https://#{HOST}"))

  @@owner : DB::Database? = nil
  @@runtime : DB::Database? = nil

  def self.url(base : String) : String
    base.sub("/caramel_spec?", "/#{NAME}?")
  end

  # The scratch database, owned by the spec role and migrated from the
  # declared schemas. The runtime role gets only CONNECT, schema USAGE and
  # DML, like a Latte runtime role.
  def self.owner : DB::Database
    @@owner ||= begin
      admin = Caramel::Database.open(ADMIN_URL, 1)
      begin
        admin.exec(%(CREATE DATABASE "#{NAME}" OWNER caramel_spec))
        admin.exec(%(REVOKE CONNECT, TEMPORARY ON DATABASE "#{NAME}" FROM PUBLIC))
        admin.exec(%(GRANT CONNECT ON DATABASE "#{NAME}" TO caramel_spec, caramel_model_spec))
      ensure
        admin.close
      end
      owner = Caramel::Database.open(url(OWNER_URL), 2)
      owner.exec("REVOKE ALL ON SCHEMA public FROM PUBLIC")
      owner.exec("GRANT USAGE ON SCHEMA public TO caramel_model_spec")
      owner.exec("ALTER DEFAULT PRIVILEGES IN SCHEMA public " \
                 "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO caramel_model_spec")
      owner.exec("ALTER DEFAULT PRIVILEGES IN SCHEMA public " \
                 "GRANT USAGE, SELECT ON SEQUENCES TO caramel_model_spec")
      SugarORM::Migrator.new(owner, Caramel::ColdBrew::MIGRATIONS + [schemas]).migrate
      owner
    end
  end

  def self.runtime : DB::Database
    @@runtime ||= Caramel::Database.open(url(RUNTIME_URL), 4)
  end

  def self.drop : Nil
    return unless @@owner
    @@runtime.try(&.close)
    @@owner.try(&.close)
    admin = Caramel::Database.open(ADMIN_URL, 1)
    admin.exec(%(DROP DATABASE IF EXISTS "#{NAME}" WITH (FORCE)))
    admin.close
  end

  # The migration that creates every declared table.
  private def self.schemas : SugarORM::Migration
    tables = SugarORM::Catalog.declared
    plan = SugarORM::Differ.diff(tables, [] of SugarORM::Catalog::Table)
    statements = SugarORM::DDL.statements(plan.transactional)
    SugarORM::Migration.new(20261003000000_i64, "create_tenancy", statements)
  end

  # A new tenant named after *slug*.
  def self.account(slug : String) : Account
    Account.create!(name: slug.capitalize, slug: slug)
  end

  def self.author(account : Account, name : String = "Ann") : Author
    Caramel::Tenancy.with(account) { Author.create!(name: name) }
  end

  # A new book of *author*'s, in *account*.
  def self.book(account : Account,
                author : Author,
                title : String,
                isbn : String = Random::Secure.hex(4)) : Book
    Caramel::Tenancy.with(account) do
      Book.create!(title: title, isbn: isbn, author_id: author.id)
    end
  end

  def self.get(path : String) : Caramel::Response
    APP.handle(HTTP::Request.new("GET", path, HTTP::Headers{"Host" => HOST}))
  end

  # What the server writes for a GET of *path*, streamed bodies included.
  def self.served(path : String) : String
    output = IO::Memory.new
    response = HTTP::Server::Response.new(output)
    request = HTTP::Request.new("GET", path, HTTP::Headers{"Host" => HOST})
    APP.call(HTTP::Server::Context.new(request, response))
    response.close
    output.to_s
  end

  # Runs every due job on the example's connection, inside its transaction.
  def self.drain : Int32
    SugarORM::Repo.connection { |connection| Caramel::ColdBrew.drain_queue!(connection) }
  end

  # What the block writes to STDOUT.
  def self.printed(&) : String
    reader, writer = IO.pipe
    saved = IO::FileDescriptor.new(LibC.dup(STDOUT.fd))
    STDOUT.flush
    STDOUT.reopen(writer)
    begin
      yield
      STDOUT.flush
    ensure
      STDOUT.reopen(saved)
      saved.close
      writer.close
    end
    reader.gets_to_end
  end
end

# Saves STDOUT's descriptor while TenancySpec.printed captures it.
lib LibC
  fun dup(fd : Int) : Int
end

Spec.before_suite do
  TenancySpec.owner
  SugarORM::Repo.database = TenancySpec.runtime
end

Spec.around_each do |example|
  SugarORM::Repo.transaction do
    example.run
    SugarORM::Repo.rollback
  end
end

Spec.after_suite { TenancySpec.drop }
