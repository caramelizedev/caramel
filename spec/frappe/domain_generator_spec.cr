require "spec"
require "file_utils"
require "../../src/frappe/new_project"
require "../../src/frappe/domain_generator"
require "../../src/frappe/tenancy_generator"

private VERSION = 20261003000001_i64
private MEANS   = "choosing teas and checking out"

private def domain_project(&)
  parent = File.tempname("caramel-domain-")
  Dir.mkdir(parent)
  package = File.expand_path("../..", __DIR__)
  target = File.join(parent, "bookshelf")
  project = Caramel::Frappe::NewProject.new(package).create("bookshelf", target)
  yield project, Caramel::Frappe::DomainGenerator.new, package
ensure
  FileUtils.rm_rf(parent) if parent
end

private def read(project : Caramel::Frappe::Project, relative : String) : String
  File.read(File.join(project.root, relative))
end

private def tenanted(project : Caramel::Frappe::Project, package : String) : Nil
  Caramel::Frappe::TenancyGenerator.new(package).generate(project, "Account", version: VERSION)
end

# Every file under the project, with its content, to prove a refusal wrote nothing.
private def snapshot(project : Caramel::Frappe::Project) : Hash(String, String)
  paths = Dir.glob(File.join(project.root, "**/*"), match: :dot_files)
  files = paths.select { |path| File.file?(path) && !path.includes?("/.caramel/") }
  files.to_h { |path| {path, File.read(path)} }
end

# Asserts that generating the domain raises *message* and changes no file.
private def refuses(project, generator, message : String, name = "Shop",
                    context = "Ordering", means = MEANS, central = false) : Nil
  before = snapshot(project)
  expect_raises(Caramel::Frappe::Error, message) do
    generator.generate(project, name, context, means, central: central)
  end
  snapshot(project).should eq(before)
end

describe Caramel::Frappe::DomainGenerator do
  it "writes the domain, its spec and the require lines" do
    domain_project do |project, generator|
      written = generator.generate(project, "Shop", "Ordering", MEANS)
      written.should eq([".claude/skills/sweettalk/SKILL.md", "app/domain/shop.cr",
                         "config/application.cr", "spec/domain/shop_spec.cr"])
    end
  end

  it "writes the SweetTalk skill from the template" do
    domain_project do |project, generator, package|
      generator.generate(project, "Shop", "Ordering", MEANS)
      template = File.read(File.join(package, "templates/skills/sweettalk/SKILL.md"))
      read(project, ".claude/skills/sweettalk/SKILL.md").should eq(template)
    end
  end

  it "keeps an edited skill" do
    domain_project do |project, generator|
      generator.generate(project, "Shop", "Ordering", MEANS)
      skill = File.join(project.root, ".claude/skills/sweettalk/SKILL.md")
      File.write(skill, "\n- Our own rule.\n", mode: "a")
      edited = File.read(skill)
      written = generator.generate(project, "Ledger", "Booking", "recording what was sold")
      written.should eq(%w[app/domain/ledger.cr spec/domain/ledger_spec.cr])
      File.read(skill).should eq(edited)
    end
  end

  it "adds the skill to an application with a domain but no skill" do
    domain_project do |project, generator|
      generator.generate(project, "Shop", "Ordering", MEANS)
      FileUtils.rm_rf(File.join(project.root, ".claude"))
      written = generator.generate(project, "Ledger", "Booking", "recording what was sold")
      written.should eq([".claude/skills/sweettalk/SKILL.md", "app/domain/ledger.cr",
                         "spec/domain/ledger_spec.cr"])
    end
  end

  it "leaves a symlinked .claude alone" do
    domain_project do |project, generator|
      target = File.tempname("caramel-claude-")
      Dir.mkdir(target)
      begin
        File.symlink(target, File.join(project.root, ".claude"))
        written = generator.generate(project, "Shop", "Ordering", MEANS)
        written.should eq(%w[app/domain/shop.cr config/application.cr spec/domain/shop_spec.cr])
        Dir.children(target).should be_empty
      ensure
        FileUtils.rm_rf(target)
      end
    end
  end

  it "requires caramel/sweet_talk after caramel and the domain before the jobs" do
    domain_project do |project, generator|
      generator.generate(project, "Shop", "Ordering", MEANS)
      config = read(project, "config/application.cr")
      opening = %(require "caramel"\nrequire "caramel/sweet_talk"\n) +
                %(require "caramel/crema/recorder"\n)
      config.should start_with(opening)
      jobs = %(require "../app/changesets/*"\nrequire "../app/domain/*"\nrequire "../app/jobs/*"\n)
      config.should contain(jobs)
    end
  end

  it "writes the module with its first context" do
    domain_project do |project, generator|
      generator.generate(project, "Shop", "Ordering", MEANS)
      read(project, "app/domain/shop.cr").should eq(<<-CRYSTAL)
        # The Shop domain, in SweetTalk (ADRs 0030 and 0031). Its words, such as
        # context, value, aggregate, event and whenever, exist only inside this module.
        module App::Shop
          include SweetTalk

          context Ordering, means: "choosing teas and checking out" do
          end
        end

        CRYSTAL
    end
  end

  it "writes a spec that reads the context's meaning" do
    domain_project do |project, generator|
      generator.generate(project, "Shop", "Ordering", MEANS)
      read(project, "spec/domain/shop_spec.cr").should eq(<<-CRYSTAL)
        require "../spec_helper"

        describe App::Shop do
          it "gives the Ordering context its meaning in the glossary" do
            term = SweetTalk.glossary.find do |entry|
              entry.kind == "context" && entry.name == "Ordering"
            end
            term.try(&.means).should eq("choosing teas and checking out")
          end
        end

        CRYSTAL
    end
  end

  it "leaves config/application.cr alone for a second domain" do
    domain_project do |project, generator|
      generator.generate(project, "Shop", "Ordering", MEANS)
      config = read(project, "config/application.cr")
      written = generator.generate(project, "Ledger", "Booking", "recording what was sold")
      written.should eq(%w[app/domain/ledger.cr spec/domain/ledger_spec.cr])
      read(project, "config/application.cr").should eq(config)
    end
  end

  it "names the tenant in a multi-tenant application" do
    domain_project do |project, generator, package|
      tenanted(project, package)
      generator.generate(project, "Shop", "Ordering", MEANS)
      expected = "  include SweetTalk\n  tenant App::Account\n\n  context Ordering, means:"
      read(project, "app/domain/shop.cr").should contain(expected)
    end
  end

  it "marks the first context central with --central" do
    domain_project do |project, generator, package|
      tenanted(project, package)
      generator.generate(project, "Catalogue", "Shelf", "the teas on our shelves", central: true)
      expected = %(context Shelf, central: true, means: "the teas on our shelves" do)
      read(project, "app/domain/catalogue.cr").should contain(expected)
    end
  end

  it "refuses each mistake, writing nothing" do
    domain_project do |project, generator|
      refuses(project, generator, "--central is for multi-tenant applications", central: true)
      [{"Shop", "Shop"}, {"shop", "Ordering"}, {"App", "Ordering"}].each do |name, context|
        refuses(project, generator, "Use class names", name, context)
      end
      [" ", "a\nb"].each do |means|
        refuses(project, generator, "Give the context a meaning", means: means)
      end
      generator.generate(project, "Shop", "Ordering", MEANS)
      refuses(project, generator, "File already exists: app/domain/shop.cr")
    end
    domain_project do |project, generator|
      path = File.join(project.root, "config/application.cr")
      File.write(path, File.read(path).sub(%(require "../app/jobs/*"\n), ""))
      refuses(project, generator, %(needs exactly one require "caramel"))
    end
    domain_project do |project, generator, package|
      tenanted(project, package)
      path = File.join(project.root, "config/routes.cr")
      File.write(path, File.read(path).sub("tenant App::Account, by: :slug do", "scope do"))
      refuses(project, generator, "has no tenant App::Model")
    end
  end
end
