require "spec"
require "file_utils"
require "./support/release_checkout"
require "../../src/frappe/new_project"
require "../../src/frappe/dev_files"

describe Caramel::Frappe::NewProject do
  it "creates a portable app that depends on this checkout, copying no framework or secrets" do
    parent = File.tempname("caramel-new-")
    Dir.mkdir(parent)
    target = File.join(parent, "reading-list")
    framework = File.expand_path("../..", __DIR__)
    begin
      generator = Caramel::Frappe::NewProject.new(framework)
      project = generator.create("reading-list", target)
      project.origin.should eq("https://reading-list.caramel")
      generated = %w[
        app/actions/application_action.cr
        app/actions/home/show.cr
        app/actions/health/show.cr
        app/models/.keep
        app/changesets/.keep
        app/views/application_view.cr
        app/views/layouts/application.cr
        app/views/home/index.cr
        config/application.cr
        config/environment.yml
        config/routes.cr
        db/seeds.cr
        src/reading_list.cr
        spec/spec_helper.cr
        spec/requests/home_spec.cr
        shard.yml
        shard.lock
        .env.example
        .env.test
        .gitignore
        .zed/settings.json
        README.md
        AGENTS.md
        CLAUDE.md
        public/assets/htmx-4.0.0.min.js
        public/assets/caramel-islands.js
      ]
      generated.each do |name|
        File.file?(File.join(target, name)).should be_true
      end
      absent = %w[.env .caramel-version vendor config/database.yml]
      absent.each { |name| File.exists?(File.join(target, name)).should be_false }
      main = File.read(File.join(target, "src/reading_list.cr"))
      main.should eq(<<-CRYSTAL + "\n")
        require "../config/application"

        Caramel.run(App)
        CRYSTAL
      # The dependency this checkout gives: a path, unless it is a clean release tag.
      source = generator.dependency
      required = <<-YAML + "\n"
          caramel:
            #{source.shard}
        YAML
      File.read(File.join(target, "shard.yml")).should contain(required)
      locked = <<-YAML + "\n"
          caramel:
            #{source.lock}
            version: #{source.version}
        YAML
      File.read(File.join(target, "shard.lock")).should contain(locked)
      lock = YAML.parse(File.read(File.join(target, "shard.lock")))["shards"]
      lock["pg"]["version"].as_s
        .should eq("0.31.0+git.commit.8b63363430edb5c09d5612f9776e6398efe48bce")
      lock["ameba"]?.should be_nil
      Caramel::Frappe::Project.pin(target).should eq(Caramel::VERSION)
      File.read(File.join(target, ".gitignore")).should contain(".env\n")
      File.read(File.join(target, "config/routes.cr")).should contain("Frappé resource routes")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "pins the native HTML parser for application specs without making it a runtime dependency" do
    framework = File.expand_path("../..", __DIR__)
    files = Caramel::Frappe::NewProject.new(framework).plan("shop")
    manifest = YAML.parse(files["shard.yml"])
    manifest["dependencies"]["lexbor"]?.should be_nil
    parser = manifest["development_dependencies"]["lexbor"]
    parser["github"].as_s.should eq("kostya/lexbor")
    parser["version"].as_s.should eq("3.6.4")

    locked = YAML.parse(files["shard.lock"])["shards"]
    locked["lexbor"]["git"].as_s.should eq("https://github.com/kostya/lexbor.git")
    locked["lexbor"]["version"].as_s
      .should eq("3.6.4+git.commit.e7028553e39cba5b7031c53668b9e38035ecac18")
    locked["ameba"]?.should be_nil
  end

  it "records the assets it publishes, so an edit before the first frappe dev publishes" do
    parent = File.tempname("caramel-new-assets-")
    Dir.mkdir(parent)
    target = File.join(parent, "notes")
    begin
      framework = File.expand_path("../..", __DIR__)
      Caramel::Frappe::NewProject.new(framework).create("notes", target)
      File.file?(File.join(target, ".caramel/assets.json")).should be_true
      source = File.join(target, "app/assets/javascript/app.js")
      File.write(source, File.read(source) + "\n// an edit before frappe dev\n")
      Caramel::Frappe::DevFiles.new(File.realpath(target)).publish_assets
      File.read(File.join(target, "public/assets/app.js")).should eq(File.read(source))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "depends on the shard its release publishes, at the published commit, only from a " \
     "checkout of the release tag without tracked changes" do
    ReleaseCheckout.create(Caramel::VERSION) do |repository|
      generator = Caramel::Frappe::NewProject.new(repository)
      checkout = "path: #{repository.to_json}"
      generator.dependency.shard.should eq(checkout)
      ReleaseCheckout.git(repository, "tag", "v#{Caramel::VERSION}")
      commit = Caramel::Frappe::Published.assembled(repository, "HEAD", &.["caramel"].commit)
      commit.should_not eq(ReleaseCheckout.git(repository, "rev-parse", "HEAD").strip)
      published = Caramel::Frappe::NewProject::Dependency.new(
        shard: %(github: example/caramel-published\n    version: "~> #{Caramel::VERSION}"),
        lock: %(git: "https://github.com/example/caramel-published.git"),
        version: "#{Caramel::VERSION}+git.commit.#{commit}",
      )
      generator.dependency.should eq(published)
      File.write(File.join(repository, "demo.txt"), "an application generated inside the clone")
      generator.dependency.should eq(published)
      manifest = File.join(repository, "shard.yml")
      File.write(manifest, File.read(manifest) + "# edited\n")
      generator.dependency.shard.should eq(checkout)
      # A source archive carries no tag to be at.
      ReleaseCheckout.git(repository, "checkout", "--", "shard.yml")
      FileUtils.rm_rf(File.join(repository, ".git"))
      generator.dependency.shard.should eq(checkout)
    end
  end

  it "depends on CARAMEL_REPOSITORY by git at this release when it is set" do
    parent = File.tempname("caramel-new-git-")
    Dir.mkdir(parent)
    ENV["CARAMEL_REPOSITORY"] = "/private/tmp/caramel-release.git"
    begin
      generator = Caramel::Frappe::NewProject.new(File.expand_path("../..", __DIR__))
      generator.create("shelf", File.join(parent, "shelf"))
      required = <<-YAML + "\n"
          caramel:
            git: "/private/tmp/caramel-release.git"
            version: "~> #{Caramel::VERSION}"
        YAML
      File.read(File.join(parent, "shelf/shard.yml")).should contain(required)
      locked = <<-YAML + "\n"
        version: 2.0
        shards:
          caramel:
            git: "/private/tmp/caramel-release.git"
            version: #{Caramel::VERSION}
        YAML
      File.read(File.join(parent, "shelf/shard.lock")).should start_with(locked)
    ensure
      ENV.delete("CARAMEL_REPOSITORY")
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves a nonempty destination and refuses invalid names before writing" do
    root = File.tempname("caramel-new-conflict-")
    Dir.mkdir(root)
    begin
      File.write(File.join(root, "notes.txt"), "keep")
      generator = Caramel::Frappe::NewProject.new(File.expand_path("../..", __DIR__))
      expect_raises(Caramel::Frappe::Error, "empty") { generator.create("bookshelf", root) }
      expect_raises(Caramel::Frappe::Error) do
        generator.create("../outside", File.join(root, "bad"))
      end
      Dir.children(root).should eq(["notes.txt"])
      File.read(File.join(root, "notes.txt")).should eq("keep")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
