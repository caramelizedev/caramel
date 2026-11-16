require "spec"
require "file_utils"
require "../../src/frappe/cli"

private ENVIRONMENT = <<-YAML
  version: 1
  name: bookshelf
  postgresql_major: 18
  extensions: []
  domain_suffix: test
  YAML

private SHARDS = "data/installs/github-crystal-lang-crystal/1.22.3/embedded/bin/shards"

# Stands in for the pinned Shards: it records its arguments, one to a line, where it ran
# and the cache it was given, lands the shards the file `landed` holds, and exits with
# the status the file `status` holds.
private STAND_IN = <<-'SH'
  #!/bin/sh
  printf '%s\n' "$@" > arguments
  pwd -P > directory
  printf '%s\n' "$SHARDS_CACHE_PATH" > cache
  echo "Shards ran"
  echo "Shards warned" >&2
  if [ -f landed ]; then
    mkdir -p lib
    cp landed lib/.shards.info
  fi
  [ ! -f status ] || exit "$(cat status)"
  SH

private LOCKED = "1.2.0+git.commit.#{"a" * 40}"
private MOVED  = "1.2.0+git.commit.#{"b" * 40}"

# A shard.lock or Shards' record of what it installed, with parser at *version*.
private def shards(version : String) : String
  <<-YAML
    version: 2.0
    shards:
      caramel:
        path: ../caramel
        version: #{Caramel::VERSION}

      parser:
        git: https://example.test/parser.git
        version: #{version}\n
    YAML
end

# One run of `frappe shards` in a project: an installation that holds scripts/shards,
# its toolchain, whose Shards is the stand-in, and a project that locks this release.
private class ShardsRun
  getter project : String
  getter toolchain : String
  getter output = IO::Memory.new
  getter errors = IO::Memory.new

  def initialize
    created = File.tempname("caramel-shards-", dir: "/private/tmp")
    Dir.mkdir(created, 0o700)
    @base = File.realpath(created)
    framework = File.join(@base, "framework")
    @toolchain = File.join(@base, "toolchain")
    @project = File.join(@base, "bookshelf")
    Dir.mkdir(@toolchain, 0o700)
    launcher = File.join(framework, "scripts/shards")
    Dir.mkdir_p(File.dirname(launcher))
    File.copy(File.expand_path("../../scripts/shards", __DIR__), launcher)
    File.chmod(launcher, 0o700)
    stand_in = File.join(@toolchain, SHARDS)
    Dir.mkdir_p(File.dirname(stand_in))
    File.write(stand_in, STAND_IN + "\n", perm: 0o700)
    Dir.mkdir_p(File.join(@project, "config"))
    File.write(File.join(@project, "config/environment.yml"), ENVIRONMENT)
    File.write(File.join(@project, "shard.lock"), shards(LOCKED))
    @frappe = Caramel::Frappe::CLI.new(framework, @output, @errors)
  end

  # Writes *content* to *name* in the project, for the stand-in to read.
  def given(name : String, content : String) : Nil
    File.write(File.join(@project, name), content)
  end

  # What the stand-in wrote to *name* in the project.
  def recorded(name : String) : String
    File.read(File.join(@project, name))
  end

  # Runs `frappe shards` with *arguments* in the project, under this run's toolchain
  # whatever toolchain runs the spec, and returns its status.
  def frappe(arguments : Array(String)) : Int32
    key = "CARAMEL_TOOLCHAIN_ROOT"
    outer = ENV[key]?
    ENV[key] = @toolchain
    begin
      Dir.cd(@project) { @frappe.run(["shards"] + arguments) }
    ensure
      ENV[key] = outer
    end
  end

  def close : Nil
    FileUtils.rm_rf(@base)
  end
end

private def shards_run(&)
  run = ShardsRun.new
  begin
    yield run
  ensure
    run.close
  end
end

describe "frappe shards" do
  it "hands its arguments to the pinned Shards unchanged, options included" do
    shards_run do |run|
      arguments = ["install", "--without-development", "--jobs=2", "-v", "two words", "--help"]
      run.frappe(arguments).should eq(0)
      run.recorded("arguments").lines.should eq(arguments)
    end
  end

  it "runs Shards with no argument when given none" do
    shards_run do |run|
      run.frappe([] of String).should eq(0)
      run.recorded("arguments").should eq("\n")
    end
  end

  it "runs Shards in the project, with the toolchain's cache and on Frappé's streams" do
    shards_run do |run|
      run.frappe(["list"]).should eq(0)
      run.recorded("directory").chomp.should eq(run.project)
      run.recorded("cache").chomp.should eq(File.join(run.toolchain, "shards-cache"))
      run.output.to_s.should eq("Shards ran\n")
      run.errors.to_s.should eq("Shards warned\n")
    end
  end

  it "exits with Shards' status" do
    shards_run do |run|
      run.given("status", "23\n")
      run.frappe(["update", "parser"]).should eq(23)
      run.errors.to_s.should eq("Shards warned\n")
    end
  end

  it "refuses an install that lands a pinned shard at another commit" do
    shards_run do |run|
      run.given("landed", shards(MOVED))
      run.frappe(["install"]).should eq(1)
      refusal = "shard parser: shard.lock pins #{LOCKED} but #{MOVED} was installed\n"
      run.errors.to_s.should end_with(refusal)
    end
  end

  it "accepts an install that lands each pinned shard at its commit" do
    shards_run do |run|
      run.given("landed", shards(LOCKED))
      run.frappe(["install"]).should eq(0)
    end
  end

  it "refuses a project that pins another release, before running Shards" do
    shards_run do |run|
      run.given("shard.lock", shards(LOCKED).sub(Caramel::VERSION, "0.0.0"))
      run.frappe(["install"]).should eq(1)
      run.errors.to_s.should contain("This project uses Caramel 0.0.0")
      File.exists?(File.join(run.project, "arguments")).should be_false
    end
  end

  it "is listed in help beside setup, and in the agent manifest" do
    command = Caramel::Frappe::Commands::TABLE.find!(&.name.==("shards"))
    started = Caramel::Frappe::Commands::GROUPS.find!(&.names.includes?("setup"))
    started.names.should contain("shards")
    output = IO::Memory.new
    frappe = Caramel::Frappe::CLI.new("/missing-framework", output, IO::Memory.new)
    frappe.run(["help"]).should eq(0)
    row = output.to_s.lines.find!(&.starts_with?("  shards "))
    row.should end_with(command.brief)
    output.clear
    frappe.run(["agent-manifest"]).should eq(0)
    output.to_s.should contain("\nfrappe shards [ARGS...]  # #{command.description}\n")
  end

  it "prints Frappé's page for frappe shards --help, without running Shards" do
    shards_run do |run|
      run.frappe(["--help"]).should eq(0)
      run.output.to_s.should contain("frappe shards [ARGS...]")
      File.exists?(File.join(run.project, "arguments")).should be_false
    end
  end
end
