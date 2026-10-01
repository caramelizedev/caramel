require "spec"
require "file_utils"

private class ShardHookFixture
  getter base : String
  getter toolchain : String
  getter script : String
  getter provided : String
  getter report : String

  def initialize
    @base = File.tempname("Caramel's Shard $hooks ")
    @toolchain = File.join(@base, "toolchain")
    @script = File.join(@base, "framework/scripts/shards")
    @provided = File.join(@base, "provided")
    @report = File.join(@base, "hook-path.txt")
    scripts = File.dirname(@script)
    Dir.mkdir_p(scripts)
    File.copy(File.expand_path("../../scripts/shards", __DIR__), @script)
    File.chmod(@script, 0o700)
    executable(File.join(scripts, "crystal"), "echo current-managed-compiler")
    executable(File.join(scripts, "check"), "echo shadowed-check")
    executable(File.join(@provided, "check"), "echo provided-check")
    executable(File.join(@toolchain, "bin/crystal"), "echo stale-managed-compiler; exit 1")
    shards = File.join(@toolchain,
      "data/installs/github-crystal-lang-crystal/1.21.1/embedded/bin/shards")
    executable(shards, <<-'SH')
      hooks=${PATH%%:*}
      printf '%s\n' "$hooks" > "$CARAMEL_SHARD_HOOK_REPORT"
      /bin/ls -A "$hooks" > "$CARAMEL_SHARD_HOOK_REPORT.contents"
      echo "arguments: $*"
      crystal postinstall.cr
      check
      exit "$CARAMEL_SHARD_HOOK_EXIT"
      SH
  end

  def invoke(exit_code = 0)
    output = IO::Memory.new
    errors = IO::Memory.new
    path = "#{@provided}:#{ENV["PATH"]?}"
    env = {
      "CARAMEL_TOOLCHAIN_ROOT"    => @toolchain,
      "CARAMEL_SHARD_HOOK_REPORT" => @report,
      "CARAMEL_SHARD_HOOK_EXIT"   => exit_code.to_s,
      "PATH"                      => path,
    }
    status = Process.run(@script, ["install", "--frozen"],
      env: env, output: output, error: errors)
    {status, output.to_s, errors.to_s}
  end

  def close : Nil
    FileUtils.rm_rf(@base)
  end

  private def executable(path, body) : Nil
    Dir.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod(path, 0o700)
  end
end

private def with_shard_hook_fixture(&)
  fixture = ShardHookFixture.new
  begin
    yield fixture
  ensure
    fixture.close
  end
end

describe "Managed Shards dependency hooks" do
  it "exposes only the current compiler and preserves commands already on PATH" do
    with_shard_hook_fixture do |fixture|
      status, output, errors = fixture.invoke
      status.success?.should be_true
      errors.should be_empty
      output.should contain("arguments: install --frozen")
      output.should contain("current-managed-compiler")
      output.should contain("provided-check")
      output.should_not contain("shadowed-check")
      output.should_not contain("stale-managed-compiler")
      File.read("#{fixture.report}.contents").strip.should eq("crystal")
      launcher = File.read(fixture.report).strip
      Dir.exists?(launcher).should be_false
    end
  end

  it "preserves Shards failure status and cleans its private hook launcher" do
    with_shard_hook_fixture do |fixture|
      status, output, errors = fixture.invoke(23)
      status.exit_code.should eq(23)
      output.should contain("current-managed-compiler")
      errors.should be_empty
      launcher = File.read(fixture.report).strip
      Dir.exists?(launcher).should be_false
    end
  end
end
