require "spec"
require "file_utils"
require "../../src/frappe/new_project"
require "../../src/frappe/tenancy_generator"

private VERSION = 20261003000001_i64

private def tenancy_project(&)
  parent = File.tempname("caramel-tenancy-")
  Dir.mkdir(parent)
  package = File.expand_path("../..", __DIR__)
  target = File.join(parent, "bookshelf")
  project = Caramel::Frappe::NewProject.new(package).create("bookshelf", target)
  yield project, Caramel::Frappe::TenancyGenerator.new(package)
ensure
  FileUtils.rm_rf(parent) if parent
end

private def read(project : Caramel::Frappe::Project, relative : String) : String
  File.read(File.join(project.root, relative))
end

# Every file under the project, with its content, to prove a refusal wrote nothing.
private def snapshot(project : Caramel::Frappe::Project) : Hash(String, String)
  paths = Dir.glob(File.join(project.root, "**/*"), match: :dot_files)
  files = paths.select { |path| File.file?(path) && !path.includes?("/.caramel/") }
  files.to_h { |path| {path, File.read(path)} }
end

# Asserts that generating Account raises *message* and changes no file.
private def refuses(project, generator, message : String, model = "Account") : Nil
  before = snapshot(project)
  expect_raises(Caramel::Frappe::Error, message) do
    generator.generate(project, model, version: VERSION)
  end
  snapshot(project).should eq(before)
end

describe Caramel::Frappe::TenancyGenerator do
  it "writes the tenant's files, migration and wiring" do
    tenancy_project do |project, generator|
      written = generator.generate(project, "Account", version: VERSION)
      written.should eq(%w[
        app/actions/accounts.cr
        app/actions/accounts/create.cr
        app/actions/accounts/home.cr
        app/actions/accounts/new.cr
        app/changesets/account.cr
        app/models/account.cr
        app/views/accounts/form.cr
        app/views/accounts/home.cr
        app/views/accounts/new.cr
        config/application.cr
        config/paths.cr
        config/routes.cr
        db/migrations/20261003000001_create_accounts.cr
        spec/requests/accounts_spec.cr
        spec/spec_helper.cr
      ])
    end
  end

  it "requires caramel/tenancy after caramel" do
    tenancy_project do |project, generator|
      generator.generate(project, "Account", version: VERSION)
      expected = %(require "caramel"\nrequire "caramel/tenancy"\n\nmodule App\n)
      read(project, "config/application.cr").should start_with(expected)
    end
  end

  it "routes the sign-up pages centrally and opens the tenant block" do
    tenancy_project do |project, generator|
      generator.generate(project, "Account", version: VERSION)
      read(project, "config/routes.cr").should eq(<<-CRYSTAL)
        module App
          Caramel::Router.draw do
            get "/", App::Home::Show
            get "/health", App::Health::Show
            get "/accounts/new", App::Accounts::New
            post "/accounts", App::Accounts::Create
            # Frappé resource routes

            tenant App::Account, by: :slug do
              get "/", App::Accounts::Home
              # Frappé tenant routes
            end
          end
        end

        CRYSTAL
    end
  end

  it "adds the tenant's path helpers" do
    tenancy_project do |project, generator|
      generator.generate(project, "Account", version: VERSION)
      read(project, "config/paths.cr").should eq(<<-CRYSTAL)
        module App::Paths
          Caramel.resource_paths :accounts, :account
          # Frappé resource paths
        end

        CRYSTAL
    end
  end

  it "gives specs a tenant and a session inside one" do
    tenancy_project do |project, generator|
      generator.generate(project, "Account", version: VERSION)
      read(project, "spec/spec_helper.cr").should end_with(<<-CRYSTAL)
        Corretto.configure(App)

        # A new Account whose pages live under /SLUG.
        def account(db, slug : String) : App::Account
          App::Account.create!(db, name: slug.capitalize, slug: slug)
        end

        # A request session in a new Account SLUG: the example's queries see
        # only its rows.
        def tenant_session(slug : String, &)
          Corretto.session do |client, db|
            Caramel::Tenancy.with(account(db, slug)) { yield client, db }
          end
        end

        CRYSTAL
    end
  end

  it "creates the tenant table with a unique slug" do
    tenancy_project do |project, generator|
      generator.generate(project, "Account", version: VERSION)
      migration = read(project, "db/migrations/20261003000001_create_accounts.cr")
      index = %(CREATE UNIQUE INDEX "index_accounts_on_slug" ON "accounts" ("slug"))
      migration.should contain(index)
    end
  end

  it "validates the slug in the tenant's changeset" do
    tenancy_project do |project, generator|
      generator.generate(project, "Account", version: VERSION)
      read(project, "app/changesets/account.cr").should contain(<<-CRYSTAL)
              cs.validate_presence(:name)
              cs.validate_tenant_slug(:slug)
              cs.unique_constraint(:slug)
        CRYSTAL
    end
  end

  it "refuses an application that is already multi-tenant, writing nothing" do
    tenancy_project do |project, generator|
      generator.generate(project, "Account", version: VERSION)
      refuses(project, generator, "already multi-tenant", "Team")
    end
  end

  it "refuses each missing anchor, writing nothing" do
    anchors = {
      "config/application.cr" => %(require "caramel"\n),
      "config/routes.cr"      => "    # Frappé resource routes\n",
      "config/paths.cr"       => "  # Frappé resource paths\n",
      "spec/spec_helper.cr"   => "Corretto.configure(App)\n",
    }
    anchors.each do |relative, anchor|
      tenancy_project do |project, generator|
        path = File.join(project.root, relative)
        File.write(path, File.read(path).sub(anchor, ""))
        refuses(project, generator, "#{relative} needs exactly one #{anchor.chomp};")
      end
    end
  end

  it "refuses a missing anchored file, writing nothing" do
    tenancy_project do |project, generator|
      File.delete(File.join(project.root, "spec/spec_helper.cr"))
      refuses(project, generator, "spec/spec_helper.cr needs exactly one Corretto.configure(App);")
    end
  end

  it "refuses a model name that is not a free class name, writing nothing" do
    tenancy_project do |project, generator|
      ["account", "Home", "../Account"].each do |model|
        refuses(project, generator, "Use a singular class name", model)
      end
    end
  end
end
