require "spec"
require "file_utils"
require "../../src/latte/watcher"

private def with_tree(&)
  created = File.tempname("caramel-watcher-", dir: "/private/tmp")
  Dir.mkdir(created)
  root = File.realpath(created)
  FileUtils.mkdir_p(File.join(root, "src/models"))
  File.write(File.join(root, "src/app.cr"), "puts 1\n")
  File.write(File.join(root, "src/models/book.cr"), "class Book; end\n")
  File.write(File.join(root, "shard.yml"), "name: probe\n")
  Dir.mkdir(File.join(root, ".caramel"))
  watcher = Caramel::Latte::Watcher.new(root, %w[src shard.yml vendor/caramel/src])
  begin
    quiet!(watcher)
    yield root, watcher
  ensure
    watcher.close
    FileUtils.rm_rf(root)
  end
end

# Consumes pending events, then proves nothing further arrives.
private def quiet!(watcher : Caramel::Latte::Watcher) : Nil
  while watcher.changed?(50.milliseconds)
  end
  watcher.changed?(150.milliseconds).should be_false
end

private def reports!(watcher : Caramel::Latte::Watcher) : Nil
  watcher.changed?(2.seconds).should be_true
  quiet!(watcher)
end

describe Caramel::Latte::Watcher do
  it "reports creation, modification and deletion inside nested watched directories" do
    with_tree do |root, watcher|
      File.write(File.join(root, "src/models/author.cr"), "class Author; end\n")
      reports!(watcher)
      File.write(File.join(root, "src/models/book.cr"), "class Book; property title = \"\"; end\n")
      reports!(watcher)
      File.open(File.join(root, "src/app.cr"), "a") { |file| file << "puts 2\n" }
      reports!(watcher)
      File.write(File.join(root, "shard.yml"), "name: renamed\n")
      reports!(watcher)
      File.delete(File.join(root, "src/models/author.cr"))
      reports!(watcher)
    end
  end

  it "keeps watching renamed and atomically replaced files" do
    with_tree do |root, watcher|
      File.rename(File.join(root, "src/app.cr"), File.join(root, "src/main.cr"))
      reports!(watcher)
      File.write(File.join(root, "src/main.cr"), "puts :renamed\n")
      reports!(watcher)
      File.write(File.join(root, "src/replacement.tmp"), "puts :replaced\n")
      reports!(watcher)
      File.rename(File.join(root, "src/replacement.tmp"), File.join(root, "src/main.cr"))
      reports!(watcher)
      File.write(File.join(root, "src/main.cr"), "puts :after_replace\n")
      reports!(watcher)
      File.rename(File.join(root, "src/models"), File.join(root, "src/records"))
      reports!(watcher)
      File.write(File.join(root, "src/records/book.cr"), "class Book; end # moved\n")
      reports!(watcher)
    end
  end

  it "watches new files inside new directories and watched paths created later" do
    with_tree do |root, watcher|
      Dir.mkdir(File.join(root, "src/actions"))
      reports!(watcher)
      File.write(File.join(root, "src/actions/show.cr"), "class Show; end\n")
      reports!(watcher)
      File.write(File.join(root, "src/actions/show.cr"), "class Show; def call; end; end\n")
      reports!(watcher)

      FileUtils.mkdir_p(File.join(root, "src/deep/er"))
      File.write(File.join(root, "src/deep/er/leaf.cr"), "1\n")
      reports!(watcher)
      File.write(File.join(root, "src/deep/er/leaf.cr"), "2\n")
      reports!(watcher)

      FileUtils.mkdir_p(File.join(root, "vendor/caramel/src"))
      reports!(watcher)
      framework = File.join(root, "vendor/caramel/src/caramel.cr")
      File.write(framework, "module Caramel; end\n")
      reports!(watcher)
      File.write(framework, "module Caramel; VERSION = 1; end\n")
      reports!(watcher)

      FileUtils.rm_rf(File.join(root, "src/deep"))
      reports!(watcher)
      FileUtils.mkdir_p(File.join(root, "src/deep"))
      reports!(watcher)
      File.write(File.join(root, "src/deep/again.cr"), "3\n")
      reports!(watcher)
    end
  end

  it "stays quiet for reads and for writes outside the watched paths" do
    with_tree do |root, watcher|
      File.read(File.join(root, "src/models/book.cr"))
      File.read(File.join(root, "shard.yml"))
      Dir.children(File.join(root, "src"))
      File.write(File.join(root, ".caramel/application"), "binary")
      watcher.changed?(200.milliseconds).should be_false
    end
  end

  it "releases every descriptor on close" do
    before = Dir.children("/dev/fd").size
    with_tree do |_, watcher|
      Dir.children("/dev/fd").size.should be > before + 4
      watcher.close
      Dir.children("/dev/fd").size.should eq(before)
    end
  end
end
