require "file_utils"
require "semantic_version"
require "yaml"
require "./installations"
require "./dispatch"
require "./launchers"
require "../latte/process"

module Caramel::Frappe
  # A tagged Caramel release on this Mac (ADR 0016). `install` clones its tag
  # into Caramel's releases directory, installs its toolchain (reusing this
  # installation's when the release pins the same one), installs its locked
  # dependencies, builds its frappe, latte and linter, and registers it.
  class Release
    getter version : String

    def initialize(@version : String, @installations : Installations, @output : IO = STDOUT, @error : IO = STDERR)
      raise Error.new("#{@version} is not a Caramel release version") unless @version.matches?(Dispatch::RELEASE)
    end

    # Where releases come from: CARAMEL_REPOSITORY, a git URL for tests and
    # forks, or Caramel's repository on GitHub.
    def self.source : String
      ENV["CARAMEL_REPOSITORY"]? || "#{Caramel::REPOSITORY}.git"
    end

    def install(toolchain : String) : String
      releases = Latte::StateSecurity.ensure_owned_directory(File.join(@installations.root, "releases"))
      root = File.join(releases, @version)
      if File.exists?(root)
        # An earlier install stopped after cloning; resume from its checkout.
        pinned = YAML.parse(File.read(File.join(root, "shard.yml")))["version"].as_s rescue nil
        raise Error.new("#{root} is not Caramel #{@version}; move it aside and install again") unless pinned == @version
      else
        clone(releases, root)
      end
      @output.puts("Installing the toolchain Caramel #{@version} pins…")
      # The toolchain installer refuses a root that pins another selection.
      reused = Latte::ProcessRunner.run([File.join(root, "scripts/install-toolchain"), "--root", toolchain, "--offline"],
        chdir: root, env: {"CARAMEL_TOOLCHAIN_ROOT" => nil}, timeout: 600.seconds, output_limit: 64 * 1024)
      run(root, "scripts/install-toolchain") unless reused.success?
      @output.puts("Building Caramel #{@version}…")
      run(root, "scripts/shards", ["install", "--frozen", "--without-development"])
      run(root, "scripts/build-frappe")
      run(root, "scripts/build-latte")
      run(root, "scripts/build-lint")
      @installations.register(@version, root)
      root
    end

    private def clone(releases : String, root : String) : Nil
      stage = File.join(releases, ".#{@version}-#{Random::Secure.hex(6)}")
      @output.puts("Cloning Caramel #{@version} from #{self.class.source}…")
      begin
        status = Process.run("/usr/bin/git", ["clone", "--quiet", "--depth", "1", "--branch", "v#{@version}", self.class.source, stage],
          output: @output, error: @error, input: Process::Redirect::Close)
        raise Error.new("Could not clone tag v#{@version} of #{self.class.source}") unless status.success?
        pinned = YAML.parse(File.read(File.join(stage, "shard.yml")))["version"].as_s
        raise Error.new("Tag v#{@version} of #{self.class.source} is Caramel #{pinned}") unless pinned == @version
        File.rename(stage, root)
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    end

    private def run(root : String, script : String, arguments : Array(String) = [] of String) : Nil
      status = Process.run(File.join(root, script), arguments, chdir: root, env: {"CARAMEL_TOOLCHAIN_ROOT" => nil},
        output: @output, error: @error, input: Process::Redirect::Close)
      raise Error.new("#{script} failed for Caramel #{@version} (exit #{status.exit_code}); its checkout is #{root}") unless status.success?
    end
  end
end
