require "spec"
require "file_utils"
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
      File.read(File.join(target, "shard.yml")).should end_with(required)
      locked = <<-YAML + "\n"
          caramel:
            #{source.lock}
            version: #{Caramel::VERSION}
        YAML
      File.read(File.join(target, "shard.lock")).should contain(locked)
      lock = YAML.parse(File.read(File.join(target, "shard.lock")))["shards"]
      lock["pg"]["version"].as_s.should eq("0.30.0")
      lock["ameba"]?.should be_nil
      Caramel::Frappe::Project.pin(target).should eq(Caramel::VERSION)
      File.read(File.join(target, ".gitignore")).should contain(".env\n")
      File.read(File.join(target, "config/routes.cr")).should contain("Frappé resource routes")
    ensure
      FileUtils.rm_rf(parent)
    end
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

  it "depends on the GitHub release only from a checkout of its tag without tracked changes" do
    repository = File.tempname("caramel-new-release-", dir: "/private/tmp")
    Dir.mkdir(repository)
    identity = ["-c", "user.name=Caramel specs", "-c", "user.email=specs@caramel.invalid"]
    git = ->(arguments : Array(String)) do
      command = ["/usr/bin/git", "-C", repository] + identity + arguments
      result = Caramel::Latte::ProcessRunner.run(command, timeout: 30.seconds)
      result.success?.should be_true
    end
    begin
      generator = Caramel::Frappe::NewProject.new(repository)
      manifest = File.join(repository, "shard.yml")
      release = <<-YAML + "\n"
        name: caramel
        version: #{Caramel::VERSION}
        YAML
      File.write(manifest, release)
      generator.dependency.shard.should eq("path: #{File.realpath(repository).to_json}")
      [
        ["init", "--quiet"],
        ["add", "--all"],
        ["commit", "--quiet", "--message", "release"],
      ].each { |arguments| git.call(arguments) }
      generator.dependency.shard.should start_with("path: ")
      git.call(["tag", "v#{Caramel::VERSION}"])
      github = Caramel::Frappe::NewProject::Dependency.new(
        shard: %(github: caramelizedev/caramel\n    version: "~> #{Caramel::VERSION}"),
        lock: %(git: "https://github.com/caramelizedev/caramel.git"),
      )
      generator.dependency.should eq(github)
      File.write(File.join(repository, "demo.txt"), "an application generated inside the clone")
      generator.dependency.shard.should start_with("github: ")
      File.write(manifest, release + "# edited\n")
      generator.dependency.shard.should start_with("path: ")
    ensure
      FileUtils.rm_rf(repository)
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
      File.read(File.join(parent, "shelf/shard.yml")).should end_with(required)
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
