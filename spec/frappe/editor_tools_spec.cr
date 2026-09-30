require "spec"
require "file_utils"
require "../../src/frappe/editor_tools"

private MANIFEST = File.expand_path("../../tools/editor-darwin-arm64.json", __DIR__)

private def with_editor_fixture(&)
  base = File.tempname("caramel-editor-tools-")
  Dir.mkdir(base, 0o700)
  begin
    framework = File.join(base, "framework")
    Dir.mkdir_p(File.join(framework, "tools"))
    File.copy(MANIFEST, File.join(framework, "tools/editor-darwin-arm64.json"))
    yield framework, editor_toolchain(base, "root-a"), editor_toolchain(base, "root-b")
  ensure
    FileUtils.rm_rf(base)
  end
end

private def editor_toolchain(base : String, name : String) : String
  root = File.join(base, name)
  Dir.mkdir(root, 0o700)
  File.write(File.join(root, ".caramel-toolchain.json"), %({"status":"complete"}))
  compiler = File.join(root, "data/installs/github-crystal-lang-crystal/1.21.1/embedded/bin")
  Dir.mkdir_p(compiler)
  File.touch(File.join(compiler, "crystal"))
  File.realpath(root)
end

describe Caramel::Frappe::EditorTools do
  it "prefers CARAMEL_TOOLCHAIN_ROOT over the installation pointer and requires one of them" do
    with_editor_fixture do |framework, root_a, root_b|
      tools = Caramel::Frappe::EditorTools.new(framework)
      expect_raises(Caramel::Frappe::Error, "frappe lsp: no Caramel toolchain is configured") do
        tools.toolchain_root({} of String => String)
      end
      File.write(File.join(framework, ".caramel-toolchain"), root_b + "\n")
      tools.toolchain_root({"CARAMEL_TOOLCHAIN_ROOT" => root_a}).should eq({root_a, "CARAMEL_TOOLCHAIN_ROOT"})
      tools.toolchain_root({} of String => String).should eq({root_b, ".caramel-toolchain"})
    end
  end

  it "refuses a missing or modified ameba-ls" do
    with_editor_fixture do |framework, root, _|
      tools = Caramel::Frappe::EditorTools.new(framework)
      env = {"CARAMEL_TOOLCHAIN_ROOT" => root}
      expect_raises(Caramel::Frappe::Error, "ameba-ls 0.2.0 is not installed in #{root} for Caramel at #{framework}") do
        tools.server("ameba-ls", env)
      end
      directory = File.join(root, "editor/ameba-ls/0.2.0")
      Dir.mkdir_p(directory)
      File.write(File.join(directory, "ameba-ls"), "not the pinned binary")
      expect_raises(Caramel::Frappe::Error, "failed verification") { tools.server("ameba-ls", env) }
    end
  end

  it "accepts a crystalline build only when its receipt matches every build input" do
    with_editor_fixture do |framework, root, _|
      tools = Caramel::Frappe::EditorTools.new(framework)
      env = {"CARAMEL_TOOLCHAIN_ROOT" => root}
      directory = File.join(root, "editor/crystalline/0.20.0+a5f6f1b-#{tools.crystalline_fingerprint}")
      Dir.mkdir_p(directory)
      binary = File.join(directory, "crystalline")
      File.write(binary, "fake crystalline")
      pins = tools.manifest
      receipt = {
        "fingerprint"      => tools.crystalline_fingerprint,
        "commit"           => pins.crystalline.commit,
        "crystal"          => pins.crystalline.crystal,
        "llvmdev_sha256"   => pins.llvmdev.sha256,
        "build_recipe"     => Caramel::Frappe::EditorTools::BUILD_RECIPE,
        "reported_version" => pins.crystalline.reported_version,
        "sha256"           => Digest::SHA256.new.file(binary).hexfinal,
      }
      File.write(File.join(directory, "receipt.json"), receipt.to_json)
      tools.server("crystalline", env).binary.should eq(binary)
      outside = File.join(framework, "identical-crystalline")
      File.rename(binary, outside)
      File.symlink(outside, binary)
      expect_raises(Caramel::Frappe::Error, "failed verification") { tools.server("crystalline", env) }
      File.delete(binary)
      File.rename(outside, binary)
      File.write(File.join(directory, "receipt.json"), receipt.merge({"llvmdev_sha256" => "0" * 64}).to_json)
      expect_raises(Caramel::Frappe::Error, "failed verification") { tools.server("crystalline", env) }
    end
  end

  it "pins the compiler source and PATH and removes loader overrides" do
    with_editor_fixture do |framework, root, _|
      tools = Caramel::Frappe::EditorTools.new(framework)
      crystal = File.join(root, "data/installs/github-crystal-lang-crystal/1.21.1")
      server = Caramel::Frappe::EditorTools::Server.new("ameba-ls", "0.2.0", "/bin/true", root, "CARAMEL_TOOLCHAIN_ROOT", crystal)
      env = tools.environment(server)
      env["CRYSTAL_PATH"].should eq("lib:#{crystal}/src")
      env["PATH"].should eq("#{crystal}/embedded/bin:#{root}/bin:/usr/bin:/bin:/usr/sbin:/sbin")
      env["DYLD_INSERT_LIBRARIES"]?.should be_nil
      env.has_key?("DYLD_INSERT_LIBRARIES").should be_true
      env["PKG_CONFIG_PATH"]?.should be_nil
      env["PKG_CONFIG_LIBDIR"].should eq(File.join(root, "data/installs/conda-openssl", Caramel::Latte::Toolchain::OPENSSL_VERSION, "lib/pkgconfig"))
      env["XDG_CACHE_HOME"].should eq(File.join(root, "editor/cache"))
      Dir.exists?(File.join(root, "editor/cache")).should be_true
    end
  end
end
