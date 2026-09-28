require "spec"
require "file_utils"
require "../../src/frappe/new_project"

describe Caramel::Frappe::NewProject do
  it "creates a portable application that depends on this checkout, with no copied framework or secrets" do
    parent = File.tempname("caramel-new-")
    Dir.mkdir(parent)
    target = File.join(parent, "reading-list")
    framework = File.expand_path("../..", __DIR__)
    begin
      generator = Caramel::Frappe::NewProject.new(framework)
      project = generator.create("reading-list", target)
      project.origin.should eq("https://reading-list.caramel")
      %w[app/actions/application_action.cr app/actions/home/show.cr app/actions/health/show.cr app/models/.keep app/changesets/.keep app/views/layouts/application.html.ecr app/views/home/index.html.ecr config/application.cr config/environment.yml config/routes.cr db/seeds.cr src/reading_list.cr spec/spec_helper.cr spec/requests/home_spec.cr shard.yml shard.lock .env.example .gitignore .zed/settings.json README.md public/assets/htmx-4.0.0.min.js public/assets/caramel-islands.js].each do |name|
        File.file?(File.join(target, name)).should be_true
      end
      %w[.env .caramel-version vendor config/database.yml].each { |name| File.exists?(File.join(target, name)).should be_false }
      File.read(File.join(target, "src/reading_list.cr")).should eq(%(require "../config/application"\n\nCaramel.run(App)\n))
      # An unreleased checkout: the application builds against it in place.
      File.read(File.join(target, "shard.yml")).should end_with("  caramel:\n    path: #{File.realpath(framework).to_json}\n")
      lock = YAML.parse(File.read(File.join(target, "shard.lock")))["shards"]
      lock["caramel"].as_h.transform_keys(&.as_s).transform_values(&.as_s).should eq({"path" => File.realpath(framework), "version" => Caramel::VERSION})
      lock["pg"]["version"].as_s.should eq("0.30.0")
      lock["ameba"]?.should be_nil
      Caramel::Frappe::Project.pin(target).should eq(Caramel::VERSION)
      File.read(File.join(target, ".gitignore")).should contain(".env\n")
      File.read(File.join(target, "config/routes.cr")).should contain("Frappé resource routes")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "depends on CARAMEL_REPOSITORY by git at this release when it is set" do
    parent = File.tempname("caramel-new-git-")
    Dir.mkdir(parent)
    ENV["CARAMEL_REPOSITORY"] = "/private/tmp/caramel-release.git"
    begin
      Caramel::Frappe::NewProject.new(File.expand_path("../..", __DIR__)).create("shelf", File.join(parent, "shelf"))
      File.read(File.join(parent, "shelf/shard.yml")).should end_with(%(  caramel:\n    git: "/private/tmp/caramel-release.git"\n    version: "~> #{Caramel::VERSION}"\n))
      File.read(File.join(parent, "shelf/shard.lock")).should start_with(%(version: 2.0\nshards:\n  caramel:\n    git: "/private/tmp/caramel-release.git"\n    version: #{Caramel::VERSION}\n))
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
      expect_raises(Caramel::Frappe::Error) { generator.create("../outside", File.join(root, "bad")) }
      Dir.children(root).should eq(["notes.txt"])
      File.read(File.join(root, "notes.txt")).should eq("keep")
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
