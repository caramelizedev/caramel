require "spec"
require "file_utils"
require "../../src/frappe/new_project"
require "../../src/frappe/resource_generator"
require "../../src/caramel/external_url"
require "../../src/caramel/html"

private def resource_project(&)
  parent = File.tempname("caramel-resource-")
  Dir.mkdir(parent)
  package = File.expand_path("../..", __DIR__)
  target = File.join(parent, "bookshelf")
  project = Caramel::Frappe::NewProject.new(package).create("bookshelf", target)
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
      fields = ["title:string", "author:string"]
      paths = generator.generate(project, "Book", fields, version: 20260919000001_i64)
      paths.should contain("app/models/book.cr")
      paths.should contain("app/changesets/book.cr")
      paths.should contain("app/actions/books.cr")
      paths.should contain("app/actions/books/index.cr")
      paths.should contain("spec/requests/books_spec.cr")
      paths.should contain("db/migrations/20260919000001_create_books.cr")
      File.read(route).should contain("# My existing route notes")
      File.read(route).should contain(%(get "/books/:id", App::Books::Show))
      helpers = File.read(File.join(project.root, "config/paths.cr"))
      helpers.should contain("Caramel.resource_paths :books, :book")
      %w[index show new edit form].each do |view|
        File.file?(File.join(project.root, "app/views/books/#{view}.cr")).should be_true
      end
      before = File.read(route)
      expect_raises(Caramel::Frappe::Error, "exists") do
        generator.generate(project, "Book", ["title:string"], version: 20260919000002_i64)
      end
      File.read(route).should eq(before)
      unwritten = File.join(project.root, "db/migrations/20260919000002_create_books.cr")
      File.exists?(unwritten).should be_false
      expect_raises(Caramel::Frappe::Error, "version") do
        generator.generate(project, "Magazine", ["title:string"], version: 20260919000001_i64)
      end
    end
  end

  it "rejects malformed declarations, reserved fields and route conflicts before writing source" do
    resource_project do |project, package|
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      ["../Book", "book", "SugarORM", "Home", "ApplicationView", "View"].each do |name|
        expect_raises(Caramel::Frappe::Error) do
          generator.generate(project, name, ["title:string"])
        end
      end
      reserved = %w[
        id created_at query with create update delete changes record errors values schema
        field timestamps if to_s
      ]
      rejected = [
        ["title:json"],
        ["title:string", "title:string"],
        ["x:string:extra"],
        ["bad-name:string"],
        ["code:string:server"],
        ["title:string:readonly"],
        ["code:string:unique:unique"],
      ]
      (rejected + reserved.map { |field| ["#{field}:string"] }).each do |fields|
        expect_raises(Caramel::Frappe::Error) { generator.generate(project, "Book", fields) }
      end
      expect_raises(Caramel::Frappe::Error, "cannot be :unique") do
        generator.generate(project, "Book", ["flag:bool:unique"])
      end
      url_refusals = {
        "link:int32:url"         => "Only a string field holds a URL",
        "link:string:server:url" => "cannot be :url",
      }
      url_refusals.each do |field, message|
        expect_raises(Caramel::Frappe::Error, message) do
          generator.generate(project, "Book", [field])
        end
      end
      expect_raises(Caramel::Frappe::Error, "63-byte") do
        generator.generate(project, "Book", ["#{"a" * 50}:string:unique"])
      end
      routes = File.join(project.root, "config/routes.cr")
      File.write(routes, "# custom routes without a generation marker\n")
      expect_raises(Caramel::Frappe::Error, "marker") do
        generator.generate(project, "Book", ["title:string"])
      end
      %w[app/models app/changesets db/migrations].each do |directory|
        Dir.children(File.join(project.root, directory)).should eq([".keep"])
      end
    end
  end

  it "keeps :server fields out of contracts, forms and request inputs, setting them on create" do
    resource_project do |project, package|
      fields = [
        "title:string?",
        "original_url:string",
        "short_code:string:server",
        "click_count:int64:server",
      ]
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      generator.generate(project, "Link", fields, version: 20260919000004_i64)
      read = ->(relative : String) { File.read(File.join(project.root, relative)) }
      read.call("app/models/link.cr").should contain("field short_code : String")
      create = read.call("app/actions/links/create.cr")
      create.should_not contain("field short_code")
      submitted = "title: contract.title, original_url: contract.original_url"
      starting = "short_code: Random::Secure.urlsafe_base64(8), click_count: 0_i64"
      create.should contain("App::Link.create(#{submitted}, #{starting})")
      read.call("app/actions/links/update.cr").should contain("record.update(#{submitted})\n")
      form = read.call("app/views/links/form.cr")
      form.should contain(%(labelled "original_url"))
      form.should_not contain(%(labelled "short_code"))
      read.call("app/views/links/show.cr").should contain("dd { @record.short_code }")
      read.call("spec/requests/links_spec.cr").should_not contain(%("short_code" =>))
    end
  end

  it "backs :unique fields with a unique index, unique_constraint and a spec duplicate check" do
    resource_project do |project, package|
      fields = [
        "email:string:unique",
        "token:string:unique:server",
        "number:int32:server:unique",
      ]
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      generator.generate(project, "Invite", fields, version: 20260919000005_i64)
      read = ->(relative : String) { File.read(File.join(project.root, relative)) }
      read.call("app/models/invite.cr").should contain(<<-CRYSTAL + "\n")
              timestamps
              index :email, unique: true
              index :token, unique: true
              index :number, unique: true
        CRYSTAL
      read.call("app/changesets/invite.cr").should contain(<<-CRYSTAL + "\n")
              cs.unique_constraint(:email)
              cs.unique_constraint(:token)
              cs.unique_constraint(:number)
        CRYSTAL

      # The :server fields' starting values.
      token = "token: Random::Secure.urlsafe_base64(8)"
      number = "number: Random::Secure.rand(Int32::MAX)"
      creation = "App::Invite.create(email: contract.email, #{token}, #{number})"
      read.call("app/actions/invites/create.cr").should contain(creation)
      index = %(CREATE UNIQUE INDEX "index_invites_on_token" ON "invites" ("token"))
      read.call("db/migrations/20260919000005_create_invites.cr").should contain(index)

      spec = read.call("spec/requests/invites_spec.cr")
      same_email = %(email: persisted.email, #{token}, #{number})
      same_token = %(email: "Example <email>", token: persisted.token, #{number})
      taken = %(?.should eq(["has already been taken"]))
      spec.should contain(%(App::Invite.create(#{same_email}).errors["email"]#{taken}))
      spec.should contain(%(App::Invite.create(#{same_token}).errors["token"]#{taken}))
    end
  end

  it "carries :url into the changeset, the form and the request spec's samples" do
    resource_project do |project, package|
      fields = ["original_url:string:url:unique", "homepage:string?:url"]
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      generator.generate(project, "Link", fields, version: 20260919000006_i64)
      read = ->(relative : String) { File.read(File.join(project.root, relative)) }

      read.call("app/changesets/link.cr").should contain(<<-CRYSTAL)
              cs.validate_presence(:original_url)
              cs.validate_url(:original_url) unless cs.errors.has_key?("original_url")
              cs.validate_url(:homepage)
              cs.unique_constraint(:original_url)
        CRYSTAL

      form = read.call("app/views/links/form.cr")
      url_input = %(input type: "url", id: id, name:)
      form.should contain(%(#{url_input} "original_url", required: true))
      form.should contain(%(#{url_input} "homepage", aria_describedby))

      original = "https://example.com/original_url?first=1&second=2"
      homepage = "https://example.org/homepage?first=2&second=3"
      spec = read.call("spec/requests/links_spec.cr")
      spec.should contain(%("original_url" => #{original.inspect}))
      spec.should contain(%("homepage" => #{homepage.inspect}))
      spec.should contain(%(blank.errors["original_url"]?.should eq(["can't be blank"])))

      # Valid links that still need escaping, so the spec's escaping check holds.
      [original, homepage].each do |sample|
        Caramel::ExternalURL.valid?(sample).should be_true
        Caramel::HTML.escape(sample).should_not eq(sample)
      end
    end
  end

  it "generates only the actions --only names, and the lines they need" do
    resource_project do |project, package|
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      refusals = {
        "index,show"              => "create and show",
        "create,show,edit,update" => "add new and update",
        "create,show,archive"     => "Unknown resource action: archive",
      }
      refusals.each do |only, message|
        expect_raises(Caramel::Frappe::Error, message) do
          generator.generate(project, "Link", ["original_url:string:url"], only: only)
        end
      end

      fields = ["original_url:string:url", "code:string:unique"]
      files = generator.generate(project, "Link", fields,
        only: "create,show", version: 20260919000007_i64)
      files.should eq(%w[
        app/actions/links/create.cr
        app/actions/links/show.cr
        app/changesets/link.cr
        app/models/link.cr
        app/views/links/show.cr
        config/paths.cr
        config/routes.cr
        db/migrations/20260919000007_create_links.cr
        spec/requests/links_spec.cr
      ])
      read = ->(relative : String) { File.read(File.join(project.root, relative)) }
      files.each { |relative| read.call(relative).should_not contain("frappe:") }

      routes = read.call("config/routes.cr")
      routes.should contain(<<-CRYSTAL)
            post "/links", App::Links::Create
            get "/links/:id", App::Links::Show
        CRYSTAL
      routes.should_not contain("App::Links::Index")

      create = read.call("app/actions/links/create.cr")
      create.should_not contain("include Form")
      create.should contain("return render_errors(changes.errors) unless changes.saved?")

      show = read.call("app/views/links/show.cr")
      show.should_not contain("links_path")
      show.should_not contain("actions")

      # The unique check saves a copy with the updated URL and the same code.
      url = "https://example.org/original_url?first=2&second=3"
      duplicate = %(App::Link.create(original_url: #{url.inspect}, code: persisted.code))
      spec = read.call("spec/requests/links_spec.cr")
      spec.should contain(%(it "creates and reads through CSRF-protected requests"))
      spec.should contain(%(client.post("/links", headers: forged, params: sample)))
      spec.should contain(%(rejected.should_not render_page("New link")))
      spec.should contain(%(section(class: "contract-errors")))
      spec.should_not contain(%(div(id: "form-errors")))
      spec.should_not contain("client.patch")
      spec.should_not contain("client.delete")
      spec.should contain(duplicate)
    end
  end

  it "loads the saved row in the request spec only when a check reads it" do
    resource_project do |project, package|
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      fields = ["points:int32", "rating:float64?"]
      generator.generate(project, "Score", fields,
        only: "create,show", version: 20260919000008_i64)
      spec = File.read(File.join(project.root, "spec/requests/scores_spec.cr"))
      spec.should_not contain("persisted")
    end
  end

  it "supports every scalar, nullable values and explicit irregular plurals" do
    resource_project do |project, package|
      fields = [
        "name:string",
        "age:int32",
        "total:int64",
        "active:bool",
        "rating:float64?",
        "joined_at:time?",
      ]
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      generator.generate(project, "Person", fields,
        plural: "people", version: 20260919000003_i64)
      model = File.read(File.join(project.root, "app/models/person.cr"))
      model.should contain("field rating : Float64?")
      model.should contain("field joined_at : Time?")
      File.read(File.join(project.root, "config/routes.cr")).should contain("App::People::Index")

      # The catalog SugarORM declares for the generated schema; frappe db diff
      # would write exactly this file for it against an empty database.
      column = ->(name : String, type : String, nullable : Bool) do
        SugarORM::Catalog::Column.new(name, type, nullable, nil)
      end
      zoned = "timestamp with time zone"
      stamp = ->(name : String) do
        SugarORM::Catalog::Column.new(name, zoned, false, "CURRENT_TIMESTAMP")
      end
      declared = SugarORM::Catalog::Table.new("people", [
        SugarORM::Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true),
        column.call("name", "text", false),
        column.call("age", "integer", false),
        column.call("total", "bigint", false),
        column.call("active", "boolean", false),
        column.call("rating", "double precision", true),
        column.call("joined_at", zoned, true),
        stamp.call("created_at"),
        stamp.call("updated_at"),
      ])
      diff = SugarORM::Differ.diff([declared], [] of SugarORM::Catalog::Table)
      statements = SugarORM::DDL.statements(diff.transactional)
      migration = SugarORM::Migration.new(20260919000003_i64, "create_people", statements)
      expected = Caramel::Frappe::SchemaDiff.source(migration)
      generated = File.join(project.root, "db/migrations/20260919000003_create_people.cr")
      File.read(generated).should eq(expected)
    end
  end
end
