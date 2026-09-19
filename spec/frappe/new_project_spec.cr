require "spec"
require "file_utils"
require "../../src/frappe/new_project"

describe Caramel::Frappe::NewProject do
  it "creates a portable application with a locked framework snapshot and no copied secrets" do
    parent = File.tempname("caramel-new-")
    Dir.mkdir(parent)
    target = File.join(parent, "reading-list")
    begin
      generator = Caramel::Frappe::NewProject.new(File.expand_path("../..", __DIR__))
      project = generator.create("reading-list", target)
      project.origin.should eq("https://reading-list.caramel")
      %w(app/controllers/application_controller.cr app/controllers/home_controller.cr app/models/application_record.cr app/views/layouts/application.html.ecr app/views/home/index.html.ecr config/application.cr config/database.yml config/environment.yml config/routes.cr db/schema.cr db/seeds.cr src/reading_list.cr spec/spec_helper.cr spec/requests/home_spec.cr shard.yml shard.lock .caramel-version .env.example .gitignore README.md vendor/caramel/src/caramel.cr vendor/caramel/snapshot.json public/assets/htmx-4.0.0.min.js).each do |name|
        File.file?(File.join(target, name)).should be_true
      end
      File.exists?(File.join(target, ".env")).should be_false
      File.read(File.join(target, "shard.yml")).should contain("path: vendor/caramel")
      File.read(File.join(target, "shard.lock")).should contain("version: 0.30.0")
      File.read(File.join(target, ".gitignore")).should contain(".env\n")
      File.read(File.join(target, "config/routes.cr")).should contain("Frappé resource routes")
      generator.verify_snapshot(project)
      File.write(File.join(target, "vendor/caramel/src/caramel/version.cr"), "changed")
      expect_raises(Caramel::Frappe::Error, "snapshot") { generator.verify_snapshot(project) }
    ensure
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
