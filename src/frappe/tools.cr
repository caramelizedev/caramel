require "./project"
require "./build_slot"
require "./dev_files"
require "./postinstall"
require "../latte/toolchain"

module Caramel::Frappe
  class Tools
    COMPILER = "data/installs/github-caramelizedev-caramel-crystal/1.22.3-caramel.1/crystal"

    getter framework_root : String
    getter toolchain : Latte::Toolchain

    def initialize(@framework_root : String, @output : IO = STDOUT, @error : IO = STDERR)
      @toolchain = begin
        Latte::Toolchain.for_checkout(@framework_root)
      rescue ex : Latte::Toolchain::Unavailable
        raise Error.new(ex.message)
      end
    end

    def environment(extra : Hash(String, String) = {} of String => String) : Hash(String, String)
      root = @toolchain.root
      values = {
        "PATH"                   => "#{root}/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "CARAMEL_TOOLCHAIN_ROOT" => root,
        "LANG"                   => "en_US.UTF-8",
      }
      %w[HOME USER LOGNAME TMPDIR].each { |key| values[key] = ENV[key] if ENV.has_key?(key) }
      values.merge!(extra)
      values
    end

    # Installs the locked dependencies, then runs their postinstall scripts
    # through the toolchain's cache of what each wrote (Postinstall).
    def dependencies(project : Project) : Nil
      refuse_unlocked(project.root)
      shards = File.join(@framework_root, "scripts/shards")
      run(shards, ["install", "--frozen", "--skip-postinstall"], project.root)
      postinstall = Postinstall.new(@framework_root, @toolchain.root, @output) do |script, dir, env|
        run("/bin/sh", ["-c", script], dir, env)
      end
      postinstall.run(project.root)
    end

    # The frozen install stops at a dependency that shard.yml names and shard.lock
    # lacks, and Shards then names its own `shards update`. Refuses first, with the
    # command that locks and installs it.
    private def refuse_unlocked(root : String) : Nil
      return unless File.file?(File.join(root, "shard.lock"))
      unlocked = named(root) - Project.locked(root).keys
      return if unlocked.empty?
      raise Error.new("shard.lock does not lock #{unlocked.join(", ")}, which shard.yml " \
                      "names; run frappe shards install to lock and install what was " \
                      "added, then frappe setup")
    end

    # Each dependency the shard.yml of the project at *root* names; none where it
    # cannot be read, which Shards then reports.
    private def named(root : String) : Array(String)
      manifest = YAML.parse(File.read(File.join(root, "shard.yml")))
      %w[dependencies development_dependencies].flat_map do |section|
        entries = manifest.as_h? ? manifest[section]?.try(&.as_h?) : nil
        entries ? entries.keys.compact_map(&.as_s?) : [] of String
      end
    rescue YAML::ParseException | File::Error
      [] of String
    end

    # Runs the pinned Shards in *project* with *arguments* as given and returns its exit
    # status. It runs through scripts/shards, the one place that selects the pinned Shards
    # and, after an install, refuses a shard that shard.lock pins to a commit and that was
    # installed at another. It keeps the caller's environment and standard input, as the
    # launcher run by hand does: a private dependency needs the caller's git credentials.
    # Shards runs the postinstall script of each shard it installs; the toolchain's cache
    # of what they wrote (Postinstall) is `dependencies`' alone.
    def shards(project : Project, arguments : Array(String)) : Int32
      launcher = File.join(@framework_root, "scripts/shards")
      status = Process.run(launcher, arguments,
        chdir: project.root,
        env: {"CARAMEL_TOOLCHAIN_ROOT" => @toolchain.root},
        output: @output,
        error: @error,
        input: Process::Redirect::Inherit)
      status.exit_code? || 1
    end

    def check_compiler : Nil
      compiler = File.join(@toolchain.root, COMPILER)
      result = Latte::ProcessRunner.run([compiler, "--version"],
        timeout: 5.seconds,
        output_limit: 4096)
      managed = result.success? && result.stdout.starts_with?("Crystal 1.22.3")
      raise Error.new("Managed Crystal 1.22.3 is unavailable") unless managed
    end

    def check_dependencies(project : Project) : Nil
      unless File.file?(File.join(project.root, "shard.lock"))
        raise Error.new("shard.lock is missing; restore it from version control")
      end
      env = environment.transform_values { |value| value.as(String?) }
      shards = File.join(@framework_root, "scripts/shards")
      result = Latte::ProcessRunner.run([shards, "check"],
        chdir: project.root,
        env: env,
        clear_env: true,
        timeout: 15.seconds,
        output_limit: 8192)
      return if result.success?
      raise Error.new("Locked dependencies are missing or inconsistent; run frappe setup")
    end

    # Builds the application for a one-shot command (ADR 0013, the shared development
    # build), or reuses a build of the same sources: `frappe dev`'s, hard-linked so its cleanup
    # cannot delete it, or the previous command's. Commands build with the
    # dev build's define, so both reuse one object set in the compiler cache
    # instead of recompiling about 170 modules at each switch. The
    # development error page it adds serves only HTTP requests, and only
    # under `CARAMEL_ENV=development`.
    def compile(project : Project) : String
      slot = BuildSlot.command(project.root, @toolchain.root)
      lock = BuildLock.application(project.root)
      begin
        lock.acquire { @error.puts("Waiting for another build of #{project.name}…") }
        fingerprint = source_fingerprint(project)
        build(project, slot, fingerprint) unless fingerprint && reused?(project, slot, fingerprint)
      ensure
        lock.release
      end
      slot.binary
    end

    # The source signature `frappe dev` builds from. Sources it cannot hash,
    # such as a symlink under src/, still build, but the build is not reused.
    private def source_fingerprint(project : Project) : String?
      DevFiles.new(project.root).snapshot.source
    rescue Error
      nil
    end

    private def reused?(project : Project, slot : BuildSlot, fingerprint : String) : Bool
      return true if slot.holds?(fingerprint)
      development = BuildSlot.development(project.root, fingerprint, @toolchain.root)
      return false unless development.holds?(fingerprint)
      slot.link(development, fingerprint)
      true
    rescue File::Error
      false
    end

    private def build(project : Project, slot : BuildSlot, fingerprint : String?) : Nil
      temporary = "#{slot.binary}-building-#{Random::Secure.hex(8)}"
      begin
        crystal = File.join(@framework_root, "scripts/crystal")
        flags = ["-D", "caramel_development", "--error-trace", "-o", temporary]
        run(crystal, ["build", project.entrypoint, *flags], project.root)
        slot.install(temporary, fingerprint)
      ensure
        File.delete?(temporary)
        File.delete?(temporary + ".dwarf")
      end
    end

    def app_command(project : Project, args : Array(String), values : Hash(String, String)) : Nil
      binary = compile(project)
      run(binary, args, project.root, values)
    end

    # Runs the command a shard contributes, *arguments* from its name on, as a command
    # of *project*'s application at *binary*, and returns its exit status. It runs in
    # development with the project's local environment, as the commands that reach the
    # database do, on the terminal's streams: what it prints appears as it is written,
    # and it reads *input*. Nil when the application registers no command of that
    # name; the application is asked first, so nothing is read into what the command
    # prints or how it exits.
    def contributed(project : Project,
                    binary : String,
                    arguments : Array(String),
                    input : Process::Stdio = Process::Redirect::Inherit) : Int32?
      values = project.local_environment.merge({"CARAMEL_ENV" => "development"})
      return unless registered(binary, project.root, values).includes?(arguments.first)
      execute(binary, arguments, project.root, values, input).exit_code? || 1
    end

    # The name of each command the application at *binary* registers: what its
    # `commands` command prints.
    def registered(binary : String,
                   directory : String,
                   values : Hash(String, String)) : Array(String)
      status, names = capture(binary, ["commands"], directory, values)
      return names.lines if status.success?
      raise Error.new("The application did not list its commands; see the diagnostic above")
    end

    def run(command : String,
            args : Array(String),
            directory : String,
            values : Hash(String, String) = {} of String => String) : Nil
      status = execute(command, args, directory, values)
      return if status.success?
      code = status.exit_code
      raise Error.new("Command failed (exit #{code}); see the diagnostic above")
    end

    # Runs a command on the terminal's streams, reading *input*, and returns its status.
    def execute(command : String,
                args : Array(String),
                directory : String,
                values : Hash(String, String) = {} of String => String,
                input : Process::Stdio = Process::Redirect::Inherit) : Process::Status
      Process.run(command, args,
        chdir: directory,
        env: environment(values),
        clear_env: true,
        output: @output,
        error: @error,
        input: input)
    end

    # Runs a command, returning its status and standard output; standard
    # error passes through to the terminal unless `error` redirects it.
    def capture(command : String,
                args : Array(String),
                directory : String,
                values : Hash(String, String) = {} of String => String,
                error : IO = @error) : Tuple(Process::Status, String)
      output = IO::Memory.new
      status = Process.run(command, args,
        chdir: directory,
        env: environment(values),
        clear_env: true,
        output: output,
        error: error,
        input: Process::Redirect::Close)
      {status, output.to_s}
    end
  end
end
