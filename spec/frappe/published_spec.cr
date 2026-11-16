require "spec"
require "digest/sha1"
require "./support/release_checkout"
require "../../src/caramel/version"

private VERSION = "0.4.2"

private alias Published = Caramel::Frappe::Published

# Yields a new directory to assemble into, and returns what the block does.
private def destination(& : String -> T) : T forall T
  directory = File.tempname("caramel-published-spec-", dir: "/private/tmp")
  Dir.mkdir(directory, 0o700)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

# The shards of *repository* with the files of each one's assembled tree.
private def assembly(repository : String, commit : String? = "HEAD")
  destination do |directory|
    shards = Published.assemble(repository, directory, commit)
    {shards, shards.transform_values { |shard| ReleaseCheckout.tree(shard.directory) }}
  end
end

# The id git gives an object of *kind* that holds *content*.
private def object_id(kind : String, content : Bytes) : Bytes
  digest = Digest::SHA1.new
  digest.update("#{kind} #{content.size}\0")
  digest.update(content)
  digest.final
end

# A tree object's line for the regular file *name* that holds *content*.
private def tree_line(name : String, content : String) : Bytes
  line = IO::Memory.new
  line << "100644 " << name << '\0'
  line.write(object_id("blob", content.to_slice))
  line.to_slice
end

# A global git configuration that would change a commit made under it.
private HOSTILE = <<-CONFIG
  [user]
    name = Someone Else
    email = else@caramel.invalid
    signingKey = 0000000000000000
  [commit]
    gpgSign = true
  [tag]
    gpgSign = true
  [init]
    defaultBranch = trunk
  [core]
    autocrlf = true
  [i18n]
    commitEncoding = ISO-8859-1

  CONFIG

# Runs the block with *variables* in the environment, and restores it.
private def with_environment(variables : Hash(String, String), &)
  before = variables.keys.to_h { |key| {key, ENV[key]?} }
  variables.each { |key, value| ENV[key] = value }
  begin
    yield
  ensure
    before.each { |key, value| ENV[key] = value }
  end
end

describe Caramel::Frappe::Published do
  it "assembles each declared shard into a repository that holds its tree and no more" do
    ReleaseCheckout.create(VERSION) do |repository|
      files = ReleaseCheckout.files(VERSION)
      shards, trees = assembly(repository)
      shards.keys.should eq(%w[caramel extra])
      trees["caramel"].should eq({
        "LICENSE"                => {files["LICENSE"].to_slice, false},
        "README.md"              => {"# Caramel, as published\n".to_slice, false},
        "shard.yml"              => {files["shard.yml"].to_slice, false},
        "src/caramel/islands.js" => {ReleaseCheckout::SCRIPT.to_slice, false},
        "src/caramel/tool"       => {files["src/caramel/tool"].to_slice, true},
        "src/caramel/view.cr"    => {files["src/caramel/view.cr"].to_slice, false},
      })
      trees["extra"].should eq({
        "LICENSE"   => {files["extra/LICENSE"].to_slice, false},
        "shard.yml" => {files["extra/shard.yml"].to_slice, false},
      })
    end
  end

  it "commits each tree once, on main, under the tag of the release's version" do
    ReleaseCheckout.create(VERSION) do |repository|
      destination do |directory|
        caramel = Published.assemble(repository, directory, "HEAD")["caramel"]
        caramel.directory.should eq(File.join(directory, "caramel"))
        published = caramel.directory
        ReleaseCheckout.git(published, "rev-list", "--all").should eq("#{caramel.commit}\n")
        named = ReleaseCheckout.git(published, "rev-parse", "v#{VERSION}", "main", "HEAD")
        named.lines.uniq!.should eq([caramel.commit])
        ReleaseCheckout.git(published, "status", "--porcelain", "--ignored").should eq("")
        tool = ReleaseCheckout.git(published, "ls-tree", caramel.commit, "src/caramel/tool")
        tool.should start_with("100755 blob ")
      end
    end
  end

  it "states where a shard is published, how a lock pins it and how to push it" do
    ReleaseCheckout.create(VERSION) do |repository|
      destination do |directory|
        extra = Published.assemble(repository, directory, "HEAD")["extra"]
        extra.repository.should eq("example/extra")
        extra.version.should eq(VERSION)
        extra.tag.should eq("v#{VERSION}")
        extra.url.should eq("https://github.com/example/extra.git")
        extra.pin.should eq("#{VERSION}+git.commit.#{extra.commit}")
        extra.push.should eq("git -C #{directory}/extra push " \
                             "https://github.com/example/extra.git +main v#{VERSION}")
      end
    end
  end

  it "gives two assemblies of one commit byte-identical trees and one commit id" do
    ReleaseCheckout.create(VERSION) do |repository|
      first, first_trees = assembly(repository)
      second, second_trees = assembly(repository)
      second_trees.should eq(first_trees)
      second.transform_values(&.commit).should eq(first.transform_values(&.commit))
    end
  end

  it "derives a commit id from the tree, a fixed author and the source commit's date" do
    ReleaseCheckout.create(VERSION) do |repository|
      files = ReleaseCheckout.files(VERSION)
      tree = IO::Memory.new
      tree.write(tree_line("LICENSE", files["extra/LICENSE"]))
      tree.write(tree_line("shard.yml", files["extra/shard.yml"]))
      commit = <<-COMMIT
        tree #{object_id("tree", tree.to_slice).hexstring}
        author Caramel <releases@caramelize.dev> #{ReleaseCheckout::SECONDS} +0000
        committer Caramel <releases@caramelize.dev> #{ReleaseCheckout::SECONDS} +0000

        extra #{VERSION}

        COMMIT
      shards, _ = assembly(repository)
      shards["extra"].commit.should eq(object_id("commit", commit.to_slice).hexstring)
    end
  end

  it "computes the same ids in a clone, whatever git is configured to do there" do
    ReleaseCheckout.create(VERSION) do |repository|
      expected, expected_trees = assembly(repository)
      destination do |machine|
        configuration = File.join(machine, "gitconfig")
        File.write(configuration, HOSTILE)
        hostile = {
          "GIT_CONFIG_GLOBAL"   => configuration,
          "GIT_AUTHOR_NAME"     => "Someone Else",
          "GIT_AUTHOR_EMAIL"    => "else@caramel.invalid",
          "GIT_AUTHOR_DATE"     => "@1 +0000",
          "GIT_COMMITTER_NAME"  => "Someone Else",
          "GIT_COMMITTER_EMAIL" => "else@caramel.invalid",
          "GIT_COMMITTER_DATE"  => "@1 +0000",
        }
        with_environment(hostile) do
          clone = File.join(machine, "clone")
          cloned = Process.run("/usr/bin/git", ["clone", "--quiet", repository, clone])
          cloned.success?.should be_true
          # The clone's checkout was converted, and its own configuration asks the same.
          File.read(File.join(clone, "LICENSE")).should eq("MIT License\r\n")
          File.write(File.join(clone, ".git/config"), HOSTILE, mode: "a")
          shards, trees = assembly(clone)
          trees.should eq(expected_trees)
          shards.transform_values(&.commit).should eq(expected.transform_values(&.commit))
        end
      end
    end
  end

  it "assembles a clean working tree as its commit, and an edited one as it is" do
    ReleaseCheckout.create(VERSION) do |repository|
      committed, committed_trees = assembly(repository)
      clean, clean_trees = assembly(repository, nil)
      clean_trees.should eq(committed_trees)
      clean.transform_values(&.commit).should eq(committed.transform_values(&.commit))

      ReleaseCheckout.write(repository, ".gitignore", "*.log\n")
      ReleaseCheckout.write(repository, "src/caramel/new.cr", "# not added yet\n")
      ReleaseCheckout.write(repository, "src/caramel/build.log", "ignored\n")
      File.delete(File.join(repository, "src/caramel/view.cr"))
      edited, edited_trees = assembly(repository, nil)
      added = %w[LICENSE README.md shard.yml] +
              %w[src/caramel/islands.js src/caramel/new.cr src/caramel/tool]
      edited_trees["caramel"].keys.should eq(added)
      edited["caramel"].commit.should_not eq(committed["caramel"].commit)
      edited["extra"].commit.should eq(committed["extra"].commit)
    end
  end

  it "refuses, naming the path, a selection its source does not hold" do
    ReleaseCheckout.create(VERSION) do |repository|
      File.delete(File.join(repository, "LICENSE"))
      missing = "published.yml: caramel selects LICENSE, which the working tree of " \
                "#{repository} does not hold"
      destination do |directory|
        expect_raises(Caramel::Frappe::Error, missing) do
          Published.assemble(repository, directory)
        end
        Published.assemble(repository, directory, "HEAD").size.should eq(2)
      end
      ReleaseCheckout.write(repository, "LICENSE", "MIT License\n")
      FileUtils.rm_rf(File.join(repository, "extra"))
      destination do |directory|
        expect_raises(Caramel::Frappe::Error, "extra selects extra, which the working tree") do
          Published.assemble(repository, directory)
        end
      end
    end
  end

  it "refuses a commit the repository does not have, and a directory that holds a shard" do
    ReleaseCheckout.create(VERSION) do |repository|
      destination do |directory|
        expect_raises(Caramel::Frappe::Error, "#{repository} has no commit v9.9.9") do
          Published.assemble(repository, directory, "v9.9.9")
        end
        Dir.mkdir(File.join(directory, "extra"))
        expect_raises(Caramel::Frappe::Error, "#{directory}/extra exists") do
          Published.assemble(repository, directory, "HEAD")
        end
        Dir.children(directory).should eq(["extra"])
      end
    end
  end

  it "refuses a selected symlink, in the working tree and in a commit" do
    ReleaseCheckout.create(VERSION) do |repository|
      File.symlink("view.cr", File.join(repository, "src/caramel/alias.cr"))
      irregular = "src/caramel/alias.cr in the working tree of #{repository} is not a regular file"
      destination do |directory|
        expect_raises(Caramel::Frappe::Error, irregular) do
          Published.assemble(repository, directory)
        end
      end
      ReleaseCheckout.git(repository, "add", "src/caramel/alias.cr")
      ReleaseCheckout.git(repository, "commit", "--quiet", "--message", "alias")
      destination do |directory|
        expect_raises(Caramel::Frappe::Error, "src/caramel/alias.cr in commit ") do
          Published.assemble(repository, directory, "HEAD")
        end
      end
    end
  end

  it "refuses a shard that takes another from elsewhere, or at another version" do
    ReleaseCheckout.create(VERSION) do |repository|
      manifest = ReleaseCheckout.files(VERSION)["extra/shard.yml"]
      elsewhere = manifest.sub("example/caramel-published", "example/caramel")
      ReleaseCheckout.write(repository, "extra/shard.yml", elsewhere)
      source = "extra/shard.yml: takes caramel from \"example/caramel\", and published.yml " \
               "publishes it to example/caramel-published"
      destination do |directory|
        expect_raises(Caramel::Frappe::Error, source) do
          Published.assemble(repository, directory)
        end
      end
      loose = manifest.sub("    version: #{VERSION}", "    version: 0.4.1")
      ReleaseCheckout.write(repository, "extra/shard.yml", loose)
      destination do |directory|
        asked = "extra/shard.yml: asks for caramel \"0.4.1\", and the release is #{VERSION}"
        expect_raises(Caramel::Frappe::Error, asked) do
          Published.assemble(repository, directory)
        end
      end
      behind = manifest.sub("version: #{VERSION}", "version: 0.4.1")
      ReleaseCheckout.write(repository, "extra/shard.yml", behind)
      destination do |directory|
        stated = "extra/shard.yml: states version \"0.4.1\", and the release is #{VERSION}"
        expect_raises(Caramel::Frappe::Error, stated) do
          Published.assemble(repository, directory)
        end
      end
    end
  end

  it "publishes of this repository only what an application compiles against" do
    framework = File.expand_path("../..", __DIR__)
    destination do |directory|
      shards = Published.assemble(framework, directory)
      shards.keys.first.should eq("caramel")
      caramel = shards["caramel"].directory
      children = ->(path : String) { Dir.children(File.join(caramel, path)).sort! }
      children.call("").should eq(%w[.git LICENSE README.md THIRD_PARTY_NOTICES.md shard.yml src])
      framework_sources = %w[caramel caramel.cr frappe latte sugar_orm sugar_orm.cr]
      children.call("src").should eq(framework_sources)
      children.call("src/frappe").should eq(%w[error.cr mrdp.cr terminal.cr toolkit.cr])
      children.call("src/latte").should eq(%w[paths.cr])
      shards.each_value do |shard|
        manifest = YAML.parse(File.read(File.join(shard.directory, "shard.yml")))
        manifest["name"].as_s.should eq(shard.name)
        manifest["version"].as_s.should eq(Caramel::VERSION)
        File.file?(File.join(shard.directory, "LICENSE")).should be_true
        File.file?(File.join(shard.directory, "README.md")).should be_true
      end
    end
  end
end
