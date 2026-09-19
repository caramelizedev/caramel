require "spec"
require "file_utils"
require "../../src/frappe/dev_files"

describe Caramel::Frappe::DevFiles do
  it "detects source edits, templates, deletions and assets while ignoring generated state" do
    root = File.tempname("caramel-watch-")
    FileUtils.mkdir_p(File.join(root, "app/views"))
    FileUtils.mkdir_p(File.join(root, "app/assets/stylesheets"))
    FileUtils.mkdir_p(File.join(root, ".caramel"))
    begin
      watcher = Caramel::Frappe::DevFiles.new(File.realpath(root))
      initial = watcher.snapshot
      File.write(File.join(root, ".caramel/application"), "binary")
      watcher.snapshot.should eq(initial)
      File.write(File.join(root, "app/views/page.html.ecr"), "hello")
      edited = watcher.snapshot
      edited.source.should_not eq(initial.source)
      edited.assets.should eq(initial.assets)
      File.write(File.join(root, "app/assets/stylesheets/app.css"), "body { color: red; }")
      styled = watcher.snapshot
      styled.source.should eq(edited.source)
      styled.assets.should_not eq(edited.assets)
      File.delete(File.join(root, "app/views/page.html.ecr"))
      watcher.snapshot.source.should eq(initial.source)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "publishes source assets, handles deletions and preserves conflicting public edits" do
    root = File.tempname("caramel-assets-")
    FileUtils.mkdir_p(File.join(root, "app/assets/stylesheets"))
    begin
      source = File.join(root, "app/assets/stylesheets/app.css")
      File.write(source, "body { color: red; }")
      assets = Caramel::Frappe::DevFiles.new(File.realpath(root))
      assets.publish_assets
      destination = File.join(root, "public/assets/app.css")
      File.read(destination).should eq(File.read(source))
      File.write(source, "body { color: blue; }")
      assets.publish_assets
      File.read(destination).should eq(File.read(source))
      File.write(destination, "a manual public edit")
      expect_raises(Caramel::Frappe::Error, "conflict") { assets.publish_assets }
      File.read(destination).should eq("a manual public edit")
      File.write(destination, File.read(source))
      File.delete(source)
      assets.publish_assets
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
