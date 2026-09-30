require "./project"
require "./build_slot"
require "./dev_files"
require "../latte/toolchain"

module Caramel::Frappe
  class Tools
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
      values = {"PATH" => "#{@toolchain.root}/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CARAMEL_TOOLCHAIN_ROOT" => @toolchain.root, "LANG" => "en_US.UTF-8"}
      %w[HOME USER LOGNAME TMPDIR].each { |key| values[key] = ENV[key] if ENV.has_key?(key) }
      values.merge!(extra)
      values
    end

    def dependencies(project : Project) : Nil
      run(File.join(@framework_root, "scripts/shards"), ["install", "--frozen"], project.root)
    end

    def check_compiler : Nil
      compiler = File.join(@toolchain.root, "data/installs/github-crystal-lang-crystal/1.21.1/embedded/bin/crystal")
      result = Latte::ProcessRunner.run([compiler, "--version"], timeout: 5.seconds, output_limit: 4096)
      raise Error.new("Managed Crystal 1.21.1 is unavailable") unless result.success? && result.stdout.starts_with?("Crystal 1.21.1")
    end

    def check_dependencies(project : Project) : Nil
      raise Error.new("shard.lock is missing; restore it from version control") unless File.file?(File.join(project.root, "shard.lock"))
      env = environment.transform_values { |value| value.as(String?) }
      result = Latte::ProcessRunner.run([File.join(@framework_root, "scripts/shards"), "check"], chdir: project.root, env: env, clear_env: true, timeout: 15.seconds, output_limit: 8192)
      raise Error.new("Locked dependencies are missing or inconsistent; run frappe setup") unless result.success?
    end

    # Builds the application for a one-shot command (ADR 0013 §5), or reuses
    # a build of the same sources: `frappe dev`'s, hard-linked so its cleanup
    # cannot delete it, or the previous command's. Commands build with the
    # dev build's define, so both reuse one object set in the compiler cache
    # instead of recompiling about 170 modules at each switch. The
    # development error page it adds serves only HTTP requests, and only
    # under `CARAMEL_ENV=development`.
    def compile(project : Project) : String
      slot = BuildSlot.command(project.root, @toolchain.root)
      lock = BuildLock.new(project.root)
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
        run(File.join(@framework_root, "scripts/crystal"), ["build", project.entrypoint, "-D", "caramel_development", "--error-trace", "-o", temporary], project.root)
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

    def run(command : String, args : Array(String), directory : String, values : Hash(String, String) = {} of String => String) : Nil
      status = execute(command, args, directory, values)
      raise Error.new("Command failed (exit #{status.exit_code}); see the diagnostic above") unless status.success?
    end

    # Runs a command on the terminal's streams and returns its status.
    def execute(command : String, args : Array(String), directory : String, values : Hash(String, String) = {} of String => String) : Process::Status
      Process.run(command, args, chdir: directory, env: environment(values), clear_env: true, output: @output, error: @error, input: Process::Redirect::Inherit)
    end

    # Runs a command, returning its status and standard output; standard
    # error passes through to the terminal unless `error` redirects it.
    def capture(command : String, args : Array(String), directory : String, values : Hash(String, String) = {} of String => String, error : IO = @error) : Tuple(Process::Status, String)
      output = IO::Memory.new
      status = Process.run(command, args, chdir: directory, env: environment(values), clear_env: true, output: output, error: error, input: Process::Redirect::Close)
      {status, output.to_s}
    end
  end
end
