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
      File.write(File.join(root, "app/views/page.cr"), "hello")
      edited = watcher.snapshot
      edited.source.should_not eq(initial.source)
      edited.assets.should eq(initial.assets)
      File.write(File.join(root, "app/assets/stylesheets/app.css"), "body { color: red; }")
      styled = watcher.snapshot
      styled.source.should eq(edited.source)
      styled.assets.should_not eq(edited.assets)
      File.delete(File.join(root, "app/views/page.cr"))
      watcher.snapshot.source.should eq(initial.source)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rebuilds after a framework edit in a path dependency, which a release never has" do
    root = File.tempname("caramel-watch-framework-")
    checkout = File.tempname("caramel-watch-checkout-")
    FileUtils.mkdir_p(File.join(root, "lib"))
    FileUtils.mkdir_p(File.join(checkout, "src/caramel"))
    File.write(File.join(checkout, "src/caramel/action.cr"), "module Caramel; end\n")
    begin
      File.symlink(checkout, File.join(root, "lib/caramel"))
      watcher = Caramel::Frappe::DevFiles.new(File.realpath(root))
      before = watcher.snapshot
      File.write(File.join(checkout, "src/caramel/action.cr"), "module Caramel; VERSION = 2; end\n")
      watcher.snapshot.source.should_not eq(before.source)
      # A release is a real directory whose version shard.lock already pins.
      File.delete(File.join(root, "lib/caramel"))
      FileUtils.cp_r(checkout, File.join(root, "lib/caramel"))
      released = watcher.snapshot
      vendored = File.join(root, "lib/caramel/src/caramel/action.cr")
      File.write(vendored, "module Caramel; VERSION = 3; end\n")
      watcher.snapshot.source.should eq(released.source)
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(checkout)
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
      recorded = File.read(File.join(root, ".caramel/assets.json"))
      published = Digest::SHA256.hexdigest(File.read(destination))
      manifest = Hash(String, String).from_json(recorded)
      manifest.should eq({"public/assets/app.css" => published})

      File.write(destination, "a manual public edit")
      remedy = "delete public/assets/app.css " \
               "to republish it from app/assets/stylesheets/app.css"
      expect_raises(Caramel::Frappe::Error, remedy) { assets.publish_assets }
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
