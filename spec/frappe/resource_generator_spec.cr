require "spec"
require "file_utils"
require "../../src/frappe/new_project"
require "../../src/frappe/resource_generator"

private def resource_project(&)
  parent = File.tempname("caramel-resource-")
  Dir.mkdir(parent)
  package = File.expand_path("../..", __DIR__)
  project = Caramel::Frappe::NewProject.new(package).create("bookshelf", File.join(parent, "bookshelf"))
  yield project, package
ensure
  FileUtils.rm_rf(parent) if parent
end

describe Caramel::Frappe::ResourceGenerator do
  it "generates readable typed CRUD and preserves custom routes and path helpers" do
    resource_project do |project, package|
      route = File.join(project.root, "config/routes.cr")
      File.open(route, "a") { |io| io.puts("# My existing route notes") }
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      paths = generator.generate(project, "Book", ["title:string", "author:string"], version: 20260919000001_i64)
      paths.should contain("app/models/book.cr")
      paths.should contain("app/changesets/book.cr")
      paths.should contain("app/actions/books.cr")
      paths.should contain("app/actions/books/index.cr")
      paths.should contain("spec/requests/books_spec.cr")
      paths.should contain("db/migrations/20260919000001_create_books.cr")
      File.read(route).should contain("# My existing route notes")
      File.read(route).should contain(%(get "/books/:id", App::Books::Show))
      File.read(File.join(project.root, "config/paths.cr")).should contain("Caramel.resource_paths :books, :book")
      %w[index show new edit form].each do |view|
        File.file?(File.join(project.root, "app/views/books/#{view}.cr")).should be_true
      end
      before = File.read(route)
      expect_raises(Caramel::Frappe::Error, "exists") { generator.generate(project, "Book", ["title:string"], version: 20260919000002_i64) }
      File.read(route).should eq(before)
      File.exists?(File.join(project.root, "db/migrations/20260919000002_create_books.cr")).should be_false
      expect_raises(Caramel::Frappe::Error, "version") { generator.generate(project, "Magazine", ["title:string"], version: 20260919000001_i64) }
    end
  end

  it "rejects malformed declarations, reserved fields and route conflicts before writing source" do
    resource_project do |project, package|
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      ["../Book", "book", "SugarORM", "Home", "ApplicationView", "View"].each do |name|
        expect_raises(Caramel::Frappe::Error) { generator.generate(project, name, ["title:string"]) }
      end
      reserved = %w[id created_at query with create update delete changes record errors values schema field timestamps if to_s]
      rejected = [["title:json"], ["title:string", "title:string"], ["x:string:extra"], ["bad-name:string"], ["code:string:server"], ["title:string:readonly"], ["code:string:unique:unique"]]
      (rejected + reserved.map { |field| ["#{field}:string"] }).each do |fields|
        expect_raises(Caramel::Frappe::Error) { generator.generate(project, "Book", fields) }
      end
      expect_raises(Caramel::Frappe::Error, "cannot be :unique") { generator.generate(project, "Book", ["flag:bool:unique"]) }
      expect_raises(Caramel::Frappe::Error, "63-byte") { generator.generate(project, "Book", ["#{"a" * 50}:string:unique"]) }
      File.write(File.join(project.root, "config/routes.cr"), "# custom routes without a generation marker\n")
      expect_raises(Caramel::Frappe::Error, "marker") { generator.generate(project, "Book", ["title:string"]) }
      %w[app/models app/changesets db/migrations].each do |directory|
        Dir.children(File.join(project.root, directory)).should eq([".keep"])
      end
    end
  end

  it "keeps :server fields out of contracts, forms and request inputs, and gives them starting values on create" do
    resource_project do |project, package|
      Caramel::Frappe::ResourceGenerator.new(package).generate(project, "Link", ["title:string?", "original_url:string", "short_code:string:server", "click_count:int64:server"], version: 20260919000004_i64)
      read = ->(relative : String) { File.read(File.join(project.root, relative)) }
      read.call("app/models/link.cr").should contain("field short_code : String")
      create = read.call("app/actions/links/create.cr")
      create.should_not contain("field short_code")
      create.should contain("App::Link.create(title: contract.title, original_url: contract.original_url, short_code: Random::Secure.urlsafe_base64(8), click_count: 0_i64)")
      read.call("app/actions/links/update.cr").should contain("record.update(title: contract.title, original_url: contract.original_url)\n")
      form = read.call("app/views/links/form.cr")
      form.should contain(%(labelled "original_url"))
      form.should_not contain(%(labelled "short_code"))
      read.call("app/views/links/show.cr").should contain("dd { @record.short_code }")
      read.call("spec/requests/links_spec.cr").should_not contain(%("short_code" =>))
    end
  end

  it "backs :unique fields with a unique index, the changeset's unique_constraint and a duplicate check in the request spec" do
    resource_project do |project, package|
      Caramel::Frappe::ResourceGenerator.new(package).generate(project, "Invite", ["email:string:unique", "token:string:unique:server", "number:int32:server:unique"], version: 20260919000005_i64)
      read = ->(relative : String) { File.read(File.join(project.root, relative)) }
      read.call("app/models/invite.cr").should contain("      timestamps\n      index :email, unique: true\n      index :token, unique: true\n      index :number, unique: true\n")
      read.call("app/changesets/invite.cr").should contain("      cs.unique_constraint(:email)\n      cs.unique_constraint(:token)\n      cs.unique_constraint(:number)\n")
      read.call("app/actions/invites/create.cr").should contain("App::Invite.create(email: contract.email, token: Random::Secure.urlsafe_base64(8), number: Random::Secure.rand(Int32::MAX))")
      read.call("db/migrations/20260919000005_create_invites.cr").should contain(%(CREATE UNIQUE INDEX "index_invites_on_token" ON "invites" ("token")))
      spec = read.call("spec/requests/invites_spec.cr")
      spec.should contain(%(App::Invite.create(email: persisted.email, token: Random::Secure.urlsafe_base64(8), number: Random::Secure.rand(Int32::MAX)).errors["email"]?.should eq(["has already been taken"])))
      spec.should contain(%(App::Invite.create(email: "Example <email>", token: persisted.token, number: Random::Secure.rand(Int32::MAX)).errors["token"]?.should eq(["has already been taken"])))
    end
  end

  it "supports every scalar, nullable values and explicit irregular plurals" do
    resource_project do |project, package|
      Caramel::Frappe::ResourceGenerator.new(package).generate(project, "Person", ["name:string", "age:int32", "total:int64", "active:bool", "rating:float64?", "joined_at:time?"], plural: "people", version: 20260919000003_i64)
      model = File.read(File.join(project.root, "app/models/person.cr"))
      model.should contain("field rating : Float64?")
      model.should contain("field joined_at : Time?")
      File.read(File.join(project.root, "config/routes.cr")).should contain("App::People::Index")

      # The catalog SugarORM declares for the generated schema; frappe db diff
      # would write exactly this file for it against an empty database.
      column = ->(name : String, type : String, nullable : Bool) { SugarORM::Catalog::Column.new(name, type, nullable, nil) }
      stamp = ->(name : String) { SugarORM::Catalog::Column.new(name, "timestamp with time zone", false, "CURRENT_TIMESTAMP") }
      declared = SugarORM::Catalog::Table.new("people", [
        SugarORM::Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true),
        column.call("name", "text", false), column.call("age", "integer", false), column.call("total", "bigint", false),
        column.call("active", "boolean", false), column.call("rating", "double precision", true),
        column.call("joined_at", "timestamp with time zone", true), stamp.call("created_at"), stamp.call("updated_at"),
      ])
      statements = SugarORM::DDL.statements(SugarORM::Differ.diff([declared], [] of SugarORM::Catalog::Table).transactional)
      expected = Caramel::Frappe::SchemaDiff.source(SugarORM::Migration.new(20260919000003_i64, "create_people", statements))
      File.read(File.join(project.root, "db/migrations/20260919000003_create_people.cr")).should eq(expected)
    end
  end
end
