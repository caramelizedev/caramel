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

private def with_build_image(value : String?, &)
  previous = ENV["CARAMEL_BUILD_IMAGE"]?
  if value
    ENV["CARAMEL_BUILD_IMAGE"] = value
  else
    ENV.delete("CARAMEL_BUILD_IMAGE")
  end
  yield
ensure
  if previous
    ENV["CARAMEL_BUILD_IMAGE"] = previous
  else
    ENV.delete("CARAMEL_BUILD_IMAGE")
  end
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
    image = Caramel::Frappe::ReleaseBuild::IMAGE
    arguments = Caramel::Frappe::ReleaseBuild.container_arguments(
      "/projects/shop/.caramel/build/work-1", [{"/x/caramel", "/x/caramel"}],
      image, "src/shop.cr", "shop", artifact)
    platform = arguments.index!("--platform")
    arguments[platform + 1].should eq("linux/amd64")
    mount = arguments.index!("/x/caramel:/x/caramel:ro")
    arguments[mount - 1].should eq("-v")
    (platform < mount && mount < arguments.index!(image)).should be_true
    arguments.last(4).should eq(["sh", "src/shop.cr", "shop", artifact])
  end

  it "uses IMAGE unless CARAMEL_BUILD_IMAGE names an image by digest" do
    digest = "sha256:" + "ab" * 32
    with_build_image(nil) do
      Caramel::Frappe::ReleaseBuild.image.should eq(Caramel::Frappe::ReleaseBuild::IMAGE)
    end
    with_build_image("ghcr.io/acme/crystal:1.22.1-alpine@#{digest}") do
      Caramel::Frappe::ReleaseBuild.image.should eq("ghcr.io/acme/crystal:1.22.1-alpine@#{digest}")
    end
    with_build_image("crystallang/crystal@#{digest}") do
      Caramel::Frappe::ReleaseBuild.image.should eq("crystallang/crystal@#{digest}")
    end
  end

  it "refuses a CARAMEL_BUILD_IMAGE without a digest" do
    ["crystallang/crystal:1.22.1-alpine", "crystallang/crystal@sha256:abc",
     "crystal:latest@sha256:" + "zz" * 32].each do |unpinned|
      with_build_image(unpinned) do
        error = expect_raises(Caramel::Frappe::Error) { Caramel::Frappe::ReleaseBuild.image }
        error.message.not_nil!.should start_with("CARAMEL_BUILD_IMAGE must name an image by digest")
        error.message.not_nil!.should end_with(unpinned.inspect)
      end
    end
  end

  it "writes the checksum as sha256sum -c reads it" do
    path = File.tempname("shop-20261011T090507Z-abc1234-linux-amd64", ".tar.gz")
    File.write(path, "not really a tarball\n")
    begin
      line = Caramel::Frappe::ReleaseBuild.checksum(path)
      digest = Digest::SHA256.hexdigest("not really a tarball\n")
      line.should eq("#{digest}  #{File.basename(path)}\n")
    ensure
      File.delete(path)
    end
  end

  it "lists the application, Crystal, the shards and the linked libraries in the SBOM" do
    versions = <<-TEXT
      Crystal 1.22.1 [23828b0a4] (2026-10-22)

      LLVM: 22.1.3
      Default target: x86_64-unknown-linux-musl
      Shards 0.20.0 [b2b98ca] (2025-12-19)
      gc-static-8.2.12-r0
      gmp-static-6.3.0-r4
      musl-1.2.6-r3
      musl-dev-1.2.6-r3
      openssl-libs-static-3.5.9-r0
      pcre2-static-10.49-r0
      zlib-static-1.3.2-r1
      TEXT
    info = <<-YAML
      version: 1.0
      shards:
        caramel:
          path: /x/caramel
          version: 0.19.0
        lexbor:
          git: https://github.com/kostya/lexbor.git
          version: 2.4.0+git.commit.0123456789abcdef0123456789abcdef01234567
      YAML
    image = Caramel::Frappe::ReleaseBuild::IMAGE
    bom = Caramel::Frappe::ReleaseBuild.sbom("shop", "abc1234", image, versions, info)
    document = JSON.parse(bom)
    document["bomFormat"].should eq("CycloneDX")
    document["specVersion"].should eq("1.5")
    document["metadata"]["component"]["name"].should eq("shop")
    document["metadata"]["component"]["version"].should eq("abc1234")
    document["metadata"]["tools"][1]["version"].should eq("0.20.0")
    document["properties"][0]["name"].should eq("caramel:build-image")
    document["properties"][0]["value"].should eq(image)
    listed = document["components"].as_a.map { |entry| {entry["name"].as_s, entry["version"].as_s} }
    listed.should eq([{"shop", "abc1234"}, {"crystal", "1.22.1"}, {"caramel", "0.19.0"},
                      {"lexbor", "2.4.0"}, {"gc", "8.2.12-r0"}, {"gmp", "6.3.0-r4"},
                      {"musl", "1.2.6-r3"}, {"openssl", "3.5.9-r0"}, {"pcre2", "10.49-r0"},
                      {"zlib", "1.3.2-r1"}])
    lexbor = document["components"][3]
    lexbor["properties"][0]["value"].should eq("0123456789abcdef0123456789abcdef01234567")
    document["components"][2]["properties"]?.should be_nil
    document["components"][7]["purl"].should eq("pkg:apk/alpine/openssl-libs-static@3.5.9-r0")
  end

  it "lists no shard without a lib/.shards.info" do
    document = JSON.parse(Caramel::Frappe::ReleaseBuild.sbom("shop", "abc1234", "img@sha256:0",
      "Crystal 1.22.1\n", nil))
    document["components"].as_a.map(&.["name"]).should eq(["shop", "crystal"])
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
