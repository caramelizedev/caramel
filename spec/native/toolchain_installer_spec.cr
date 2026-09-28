require "spec"
require "../../scripts/checks/support/harness"

TOOLCHAIN_INSTALLER      = File.join(Caramel::Checks::REPO, "bin/install-toolchain")
TOOLCHAIN_TEST_INSTALLER = File.join(Caramel::Checks::REPO, "bin/test/install-toolchain")
raise "Run scripts/check native" unless File.file?(TOOLCHAIN_INSTALLER) && File.file?(TOOLCHAIN_TEST_INSTALLER)

private class NativeToolchainFixture
  getter base : String
  getter root : String
  getter config : String
  getter pointer : String
  getter critical : Array(String)

  def initialize
    @base = Caramel::Checks.private_temp("caramel-toolchain-native-")
    @root = File.join(@base, "Toolchain With Spaces")
    @config = File.join(@base, "fixture.json")
    @pointer = File.join(@base, "checkout.caramel-toolchain")
    @critical = ["bin/mise", "data/installs/test/bin/compiler"]
    configure("create-critical")
  end

  def configure(provider : String, lock : String = "version = 1\n") : Nil
    File.write(@config, {
      "payloads" => {"project/caramel-toolchain.toml" => "[tools]\n", "project/mise.lock" => lock},
      "critical" => @critical,
      "aliases"  => {} of String => String,
      "provider" => provider,
      "pointer"  => @pointer,
    }.to_json)
  end

  def invoke(args : Array(String) = [] of String, production : Bool = false) : Caramel::Latte::ProcessResult
    command = production ? TOOLCHAIN_INSTALLER : TOOLCHAIN_TEST_INSTALLER
    Caramel::Checks.run([command, "--root", @root] + args,
      env: {"CARAMEL_INSTALLER_FIXTURE" => (production ? nil : @config)}, timeout: 35.seconds)
  end

  def complete : Nil
    result = invoke
    raise "fixture install failed: #{result.stderr}" unless result.success?
  end

  def receipt : JSON::Any
    JSON.parse(File.read(File.join(@root, ".caramel-toolchain.json")))
  end

  def close : Nil
    FileUtils.rm_rf(@base)
  end
end

private def with_toolchain_fixture(& : NativeToolchainFixture ->) : Nil
  fixture = NativeToolchainFixture.new
  begin
    yield fixture
  ensure
    fixture.close
  end
end

private def expect_toolchain_error(result : Caramel::Latte::ProcessResult, expected : String) : Nil
  result.success?.should be_false
  result.status.exit_code.should eq(1)
  result.stderr.should contain("install-toolchain: #{expected}")
end

private def toolchain_probe(fixture : NativeToolchainFixture, stdout : String, stderr : String, expected : String) : Caramel::Latte::ProcessResult
  output = File.join(fixture.base, "stdout.txt")
  errors = File.join(fixture.base, "stderr.txt")
  File.write(output, stdout)
  File.write(errors, stderr)
  Caramel::Checks.run([TOOLCHAIN_TEST_INSTALLER, "test-probe", "--root", fixture.root,
                       "--expected", expected, "--stdout", output, "--stderr", errors], timeout: 20.seconds)
end

describe "Swift toolchain installer" do
  it "refuses a nonempty unrelated root without modifying its contents" do
    with_toolchain_fixture do |fixture|
      Dir.mkdir(fixture.root, 0o700)
      note = File.join(fixture.root, "notes.txt")
      File.write(note, "keep me")
      expect_toolchain_error(fixture.invoke(production: true), "refusing a nonempty directory without a Caramel receipt")
      File.read(note).should eq("keep me")
      Dir.children(fixture.root).sort.should eq(["notes.txt"])
    end
  end

  it "refuses an installer lock held by another process" do
    with_toolchain_fixture do |fixture|
      Dir.mkdir(fixture.root, 0o700)
      File.open(File.join(fixture.root, ".install.lock"), "a", perm: 0o600) do |lock|
        lock.flock_exclusive do
          expect_toolchain_error(fixture.invoke(production: true), "another Caramel toolchain installer is already running")
        end
      end
    end
  end

  it "fails offline before creating an absent root" do
    with_toolchain_fixture do |fixture|
      expect_toolchain_error(fixture.invoke(["--offline"], production: true), "offline use requires a completed verified installation")
      File.exists?(fixture.root).should be_false
    end
  end

  it "preserves altered authored content on a resumable installation" do
    with_toolchain_fixture do |fixture|
      fixture.configure("fail")
      expect_toolchain_error(fixture.invoke, "fixture provider failed")
      authored = File.join(fixture.root, "project/caramel-toolchain.toml")
      File.write(authored, "[tasks.unreviewed]\n")
      expect_toolchain_error(fixture.invoke, "authored toolchain file differs; preserved: project/caramel-toolchain.toml")
      File.read(authored).should eq("[tasks.unreviewed]\n")
    end
  end

  it "verifies a completed installation offline without calling the provider" do
    with_toolchain_fixture do |fixture|
      fixture.complete
      fixture.configure("fail")
      result = fixture.invoke(["--offline"])
      result.success?.should be_true
      result.stdout.should contain("Verified installed Caramel toolchain: #{fixture.root}")
      fixture.receipt["status"].as_s.should eq("complete")
    end
  end

  it "records the toolchain for the checkout after installing and after verifying" do
    with_toolchain_fixture do |fixture|
      fixture.complete
      File.read(fixture.pointer).should eq("#{fixture.root}\n")
      (File.info(fixture.pointer).permissions.value & 0o777).should eq(0o644)
      File.delete(fixture.pointer)
      fixture.configure("fail")
      result = fixture.invoke(["--offline"])
      result.success?.should be_true
      result.stdout.should contain("Recorded in #{fixture.pointer}")
      File.read(fixture.pointer).should eq("#{fixture.root}\n")
    end
  end

  it "installs into Caramel's toolchains directory when no root is given" do
    with_toolchain_fixture do |fixture|
      home = File.join(fixture.base, "Caramel Home")
      result = Caramel::Checks.run([TOOLCHAIN_TEST_INSTALLER],
        env: {"CARAMEL_INSTALLER_FIXTURE" => fixture.config, "CARAMEL_HOME" => home}, timeout: 35.seconds)
      result.success?.should be_true
      root = File.read(fixture.pointer).chomp
      File.dirname(root).should eq(File.join(home, "toolchains"))
      File.basename(root).should match(/\A[0-9a-f]{12}\z/)
      result.stdout.should contain("Installed and verified Caramel toolchain: #{root}")
      (File.info(home).permissions.value & 0o777).should eq(0o700)
      again = Caramel::Checks.run([TOOLCHAIN_TEST_INSTALLER, "--offline"],
        env: {"CARAMEL_INSTALLER_FIXTURE" => fixture.config, "CARAMEL_HOME" => home}, timeout: 35.seconds)
      again.stdout.should contain("Verified installed Caramel toolchain: #{root}")
    end
  end

  it "reuses the toolchain the checkout records when no root is given" do
    with_toolchain_fixture do |fixture|
      fixture.complete
      fixture.configure("fail")
      home = File.join(fixture.base, "Caramel Home")
      result = Caramel::Checks.run([TOOLCHAIN_TEST_INSTALLER],
        env: {"CARAMEL_INSTALLER_FIXTURE" => fixture.config, "CARAMEL_HOME" => home}, timeout: 35.seconds)
      result.success?.should be_true
      result.stdout.should contain("Verified installed Caramel toolchain: #{fixture.root}")
      File.exists?(home).should be_false
    end
  end

  it "refuses a recorded pointer that others can write when no root is given" do
    with_toolchain_fixture do |fixture|
      fixture.complete
      File.chmod(fixture.pointer, 0o666)
      home = File.join(fixture.base, "Caramel Home")
      result = Caramel::Checks.run([TOOLCHAIN_TEST_INSTALLER],
        env: {"CARAMEL_INSTALLER_FIXTURE" => fixture.config, "CARAMEL_HOME" => home}, timeout: 35.seconds)
      expect_toolchain_error(result, "#{fixture.pointer} must be a regular file you own that no one else can write")
      File.exists?(home).should be_false
    end
  end

  it "installs a changed release beside the recorded toolchain when no root is given" do
    with_toolchain_fixture do |fixture|
      fixture.complete
      fixture.configure("create-critical", "version = 2\n")
      home = File.join(fixture.base, "Caramel Home")
      result = Caramel::Checks.run([TOOLCHAIN_TEST_INSTALLER],
        env: {"CARAMEL_INSTALLER_FIXTURE" => fixture.config, "CARAMEL_HOME" => home}, timeout: 35.seconds)
      result.success?.should be_true
      root = File.read(fixture.pointer).chomp
      File.dirname(root).should eq(File.join(home, "toolchains"))
      result.stdout.should contain("Installed and verified Caramel toolchain: #{root}")
      fixture.receipt["status"].as_s.should eq("complete")
    end
  end

  it "refuses modified critical binaries and leaves them untouched" do
    with_toolchain_fixture do |fixture|
      fixture.complete
      binary = File.join(fixture.root, fixture.critical.last)
      File.write(binary, "changed")
      expect_toolchain_error(fixture.invoke(["--offline"]), "toolchain artifact verification failed; preserve this prefix for inspection")
      File.read(binary).should eq("changed")
    end
  end

  it "refuses receipts with a missing artifact inventory key" do
    with_toolchain_fixture do |fixture|
      fixture.complete
      receipt_path = File.join(fixture.root, ".caramel-toolchain.json")
      receipt = fixture.receipt
      receipt["artifacts"].as_h.delete(fixture.critical.last)
      File.write(receipt_path, receipt.to_json)
      expect_toolchain_error(fixture.invoke(["--offline"]), "toolchain artifact inventory verification failed")
    end
  end

  it "rejects symlinked data roots without writing into external directories" do
    with_toolchain_fixture do |fixture|
      fixture.configure("fail")
      expect_toolchain_error(fixture.invoke, "fixture provider failed")
      outside = File.join(fixture.base, "external")
      Dir.mkdir(outside, 0o700)
      File.rename(File.join(fixture.root, "data"), File.join(fixture.root, "data.original"))
      File.symlink(outside, File.join(fixture.root, "data"))
      result = fixture.invoke
      expect_toolchain_error(result, "expected an owned directory (no symlink):")
      Dir.children(outside).should be_empty
    end
  end

  it "resumes after a failed provider and completes without changing authored files" do
    with_toolchain_fixture do |fixture|
      fixture.configure("fail")
      expect_toolchain_error(fixture.invoke, "fixture provider failed")
      fixture.receipt["status"].as_s.should eq("installing")
      original = File.read(File.join(fixture.root, "project/caramel-toolchain.toml"))
      fixture.configure("create-critical")
      fixture.complete
      File.read(File.join(fixture.root, "project/caramel-toolchain.toml")).should eq(original)
      fixture.receipt["status"].as_s.should eq("complete")
    end
  end

  it "rejects a completed installation moved to another root" do
    with_toolchain_fixture do |fixture|
      fixture.complete
      moved = File.join(fixture.base, "moved Toolchain With Spaces")
      File.rename(fixture.root, moved)
      result = Caramel::Checks.run([TOOLCHAIN_TEST_INSTALLER, "--root", moved],
        env: {"CARAMEL_INSTALLER_FIXTURE" => fixture.config}, timeout: 35.seconds)
      expect_toolchain_error(result, "installation was moved; install into a fresh prefix")
    end
  end

  it "rejects native libraries loaded from other package managers" do
    with_toolchain_fixture do |fixture|
      result = toolchain_probe(fixture, "Crystal 1.21.0\n", "dyld[123]: <ABCD> /opt/homebrew/lib/libssl.3.dylib\n", "Crystal 1.21.0")
      expect_toolchain_error(result, "native tool loaded a library outside Caramel or macOS:")
    end
  end

  it "accepts only observed permitted libraries with the expected native version" do
    with_toolchain_fixture do |fixture|
      stderr = "dyld[123]: <ABCD> #{fixture.root}/bin/compiler\ndyld[123]: <1234> /usr/lib/libSystem.B.dylib\n"
      result = toolchain_probe(fixture, "Crystal 1.21.0\n", stderr, "Crystal 1.21.0")
      result.success?.should be_true
      JSON.parse(result.stdout).as_a.map(&.as_s).should eq(["#{fixture.root}/bin/compiler", "/usr/lib/libSystem.B.dylib"])
      expect_toolchain_error(toolchain_probe(fixture, "Crystal 1.21.0\n", stderr, "Crystal 1.20.0"), "native tool version/output differs")
      expect_toolchain_error(toolchain_probe(fixture, "Crystal 1.21.0\n", "", "Crystal 1.21.0"), "native library evidence is unavailable")
    end
  end

  it "isolates mise from ancestor configuration and inherited secrets" do
    with_toolchain_fixture do |fixture|
      Dir.mkdir(fixture.root, 0o700)
      File.write(File.join(fixture.base, "mise.toml"), "[tasks.sentinel]\nrun = 'false'\n")
      result = Caramel::Checks.run([TOOLCHAIN_TEST_INSTALLER, "test-environment", "--root", fixture.root],
        env: {"SECRET_SHOULD_NOT_CROSS" => "redacted"}, timeout: 20.seconds)
      result.success?.should be_true
      env = JSON.parse(result.stdout).as_h
      env.has_key?("SECRET_SHOULD_NOT_CROSS").should be_false
      env.has_key?("MISE_TRUSTED_CONFIG_PATHS").should be_false
      expected = {
        "MISE_CEILING_PATHS" => fixture.root,
        "MISE_OVERRIDE_CONFIG_FILENAMES" => "caramel-toolchain.toml",
        "MISE_NO_ENV" => "1", "MISE_NO_HOOKS" => "1", "MISE_NETRC" => "0",
        "MISE_AUTO_INSTALL" => "0", "MISE_PARANOID" => "1",
      }
      expected.each { |name, value| env[name].as_s.should eq(value) }
      directories = %w[data cache state config system-config system-data xdg-cache xdg-config xdg-data xdg-state mamba crystal-cache]
      directories.each { |name| Dir.exists?(File.join(fixture.root, name)).should be_true }
      File.file?(File.join(fixture.root, "config/empty.toml")).should be_true
      File.file?(File.join(fixture.root, "system-config/empty.toml")).should be_true
    end
  end
end
