require "spec"
require "file_utils"
require "../../src/frappe/new_project"
require "../../src/frappe/locale_generator"

private def locale_project(&)
  parent = File.tempname("caramel-locale-")
  Dir.mkdir(parent)
  package = File.expand_path("../..", __DIR__)
  target = File.join(parent, "bookshelf")
  project = Caramel::Frappe::NewProject.new(package).create("bookshelf", target)
  yield project, Caramel::Frappe::LocaleGenerator.new
ensure
  FileUtils.rm_rf(parent) if parent
end

private def read(project : Caramel::Frappe::Project, relative : String) : String
  File.read(File.join(project.root, relative))
end

private def locales(project : Caramel::Frappe::Project) : Array(String)
  directory = File.join(project.root, "app/locales")
  Dir.exists?(directory) ? Dir.children(directory).sort : [] of String
end

describe Caramel::Frappe::LocaleGenerator do
  it "wires i18n into config/application.cr on first use" do
    locale_project do |project, generator|
      generator.generate(project, "fr")
      config = read(project, "config/application.cr")
      config.should contain(%(require "caramel"\nrequire "caramel/i18n"\n))
      wiring = <<-CRYSTAL
        require "./paths"
        require "../app/locales/*"
        Caramel.locales default: "en"

        require "../app/views/application_view"
        CRYSTAL
      config.should contain(wiring)
    end
  end

  it "writes the English catalog and the new locale's catalog" do
    locale_project do |project, generator|
      written = generator.generate(project, "fr")
      written.should eq(%w[app/locales/en.cr app/locales/fr.cr config/application.cr])
      read(project, "app/locales/en.cr").should contain("  # Frappé resource messages\n}\n")
      read(project, "app/locales/fr.cr").should contain(%(Caramel.locale "fr", {))
    end
  end

  it "adds only the catalog on a later run" do
    locale_project do |project, generator|
      generator.generate(project, "fr")
      generator.generate(project, "pt-BR").should eq(%w[app/locales/pt-BR.cr])
    end
  end

  it "refuses a locale that already exists" do
    locale_project do |project, generator|
      generator.generate(project, "fr")
      expect_raises(Caramel::Frappe::Error, "Locale fr already exists: app/locales/fr.cr") do
        generator.generate(project, "fr")
      end
    end
  end

  it "refuses a configuration without its anchors, writing nothing" do
    locale_project do |project, generator|
      config = File.join(project.root, "config/application.cr")
      original = File.read(config).sub(%(require "caramel"\n), "")
      File.write(config, original)
      expect_raises(Caramel::Frappe::Error, "needs exactly one require") do
        generator.generate(project, "fr")
      end
      File.read(config).should eq(original)
      locales(project).should be_empty
    end
  end

  it "refuses a code that is not a language tag" do
    locale_project do |project, generator|
      expect_raises(Caramel::Frappe::Error, "Use a locale code such as fr") do
        generator.generate(project, "../fr")
      end
      locales(project).should be_empty
    end
  end
end
