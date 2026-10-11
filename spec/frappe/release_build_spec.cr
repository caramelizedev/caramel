require "spec"
require "file_utils"
require "../../src/frappe/release_build"

private def release_fixture(&)
  root = File.tempname("caramel-release-")
  Dir.mkdir(root)
  Dir.mkdir(File.join(root, "config"))
  File.write(File.join(root, "shard.lock"), <<-YAML)
    version: 2.0
    shards:
      caramel:
        path: /private/tmp/caramel
        version: #{Caramel::VERSION}\n
    YAML
  File.write(File.join(root, "config/environment.yml"), <<-YAML)
    version: 1
    name: bookshelf
    postgresql_major: 18
    extensions: []
    domain_suffix: caramel
    YAML
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

private def release_git(root : String, *arguments : String) : Nil
  identity = ["-c", "user.name=Caramel", "-c", "user.email=checks@caramel.invalid",
              "-c", "commit.gpgsign=false"]
  status = Process.run("/usr/bin/git", ["-C", root] + identity + arguments.to_a)
  raise "git #{arguments.first} failed" unless status.success?
end

describe Caramel::Frappe::ReleaseBuild do
  it "names the artifact after the shard, the UTC build time and the commit" do
    time = Time.utc(2026, 10, 11, 9, 5, 7)
    name = Caramel::Frappe::ReleaseBuild.artifact_name("shop", time, "abc1234")
    name.should eq("shop-20261011T090507Z-abc1234-linux-amd64.tar.gz")
    name.should match(Caramel::Frappe::ReleaseBuild::ARTIFACT)
  end

  it "mounts runtime path dependencies and leaves development ones out" do
    caramel = File.tempname("caramel-path-dependency-")
    Dir.mkdir(caramel)
    begin
      manifest = <<-YAML
        name: shop
        dependencies:
          caramel:
            path: #{caramel}
        development_dependencies:
          lexbor:
            path: /nowhere/lexbor
        YAML
      mounts = Caramel::Frappe::ReleaseBuild.path_mounts(manifest, "/projects/shop")
      mounts.should eq([{caramel, caramel}])
    ensure
      Dir.delete(caramel)
    end
  end

  it "refuses a path dependency that does not exist" do
    manifest = "dependencies:\n  caramel:\n    path: ../missing-caramel\n"
    message = "Path dependency caramel points to ../missing-caramel, which does not exist"
    expect_raises(Caramel::Frappe::Error, message) do
      Caramel::Frappe::ReleaseBuild.path_mounts(manifest, "/nowhere/shop")
    end
  end

  it "runs the pinned image for linux/amd64 with the dependencies read-only" do
    artifact = "shop-20261011T090507Z-abc1234-linux-amd64.tar.gz"
    arguments = Caramel::Frappe::ReleaseBuild.container_arguments(
      "/projects/shop/.caramel/build/work-1", [{"/x/caramel", "/x/caramel"}],
      "src/shop.cr", "shop", artifact)
    image = Caramel::Frappe::ReleaseBuild::IMAGE
    platform = arguments.index!("--platform")
    arguments[platform + 1].should eq("linux/amd64")
    mount = arguments.index!("/x/caramel:/x/caramel:ro")
    arguments[mount - 1].should eq("-v")
    (platform < mount && mount < arguments.index!(image)).should be_true
    arguments.last(4).should eq(["sh", "src/shop.cr", "shop", artifact])
  end

  it "refuses a working tree with uncommitted changes" do
    release_fixture do |root|
      release_git(root, "init", "-q")
      release_git(root, "add", "-A")
      release_git(root, "commit", "-qm", "build")
      File.write(File.join(root, "dirty.txt"), "not committed\n")
      project = Caramel::Frappe::Project.load(root)
      error = expect_raises(Caramel::Frappe::Error) do
        Caramel::Frappe::ReleaseBuild.new(project, IO::Memory.new).run
      end
      error.message.not_nil!.should start_with("The working tree has uncommitted changes")
      error.message.not_nil!.should contain("?? dirty.txt")
    end
  end

  it "refuses a project outside a git repository" do
    release_fixture do |root|
      project = Caramel::Frappe::Project.load(root)
      message = "frappe build needs a git repository with a commit; run git init and commit first"
      expect_raises(Caramel::Frappe::Error, message) do
        Caramel::Frappe::ReleaseBuild.new(project, IO::Memory.new).run
      end
    end
  end
end
