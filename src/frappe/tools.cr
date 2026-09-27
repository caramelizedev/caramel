require "./project"
require "../latte/toolchain"

module Caramel::Frappe
  class Tools
    getter framework_root : String
    getter toolchain : Latte::Toolchain

    def initialize(@framework_root : String, @output : IO = STDOUT, @error : IO = STDERR)
      @toolchain = begin
        Latte::Toolchain.new
      rescue ex : Latte::Toolchain::Unavailable
        raise Error.new(ex.message)
      end
    end

    def environment(extra : Hash(String, String) = {} of String => String) : Hash(String, String)
      values = {"PATH" => "#{@toolchain.root}/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CARAMEL_TOOLCHAIN_ROOT" => @toolchain.root, "LANG" => "en_US.UTF-8"}
      %w(HOME USER LOGNAME TMPDIR).each { |key| values[key] = ENV[key] if ENV.has_key?(key) }
      values.merge!(extra)
      values
    end

    def dependencies(project : Project) : Nil
      run(File.join(@framework_root, "scripts/shards"), ["install", "--frozen"], project.root)
    end

    def check_compiler : Nil
      compiler = File.join(@toolchain.root, "data/installs/github-crystal-lang-crystal/1.21.0/embedded/bin/crystal")
      result = Latte::ProcessRunner.run([compiler, "--version"], timeout: 5.seconds, output_limit: 4096)
      raise Error.new("Managed Crystal 1.21.0 is unavailable") unless result.success? && result.stdout.starts_with?("Crystal 1.21.0")
    end

    def check_dependencies(project : Project) : Nil
      raise Error.new("shard.lock is missing; restore it from version control") unless File.file?(File.join(project.root, "shard.lock"))
      env = environment.transform_values { |value| value.as(String?) }
      result = Latte::ProcessRunner.run([File.join(@framework_root, "scripts/shards"), "check"], chdir: project.root, env: env, clear_env: true, timeout: 15.seconds, output_limit: 8192)
      raise Error.new("Locked dependencies are missing or inconsistent; run frappe setup") unless result.success?
    end

    def compile(project : Project) : String
      directory = Latte::StateSecurity.ensure_owned_directory(File.join(project.root, ".caramel"))
      binary = File.join(directory, "application")
      run(File.join(@framework_root, "scripts/crystal"), ["build", project.entrypoint, "--error-trace", "-o", binary], project.root)
      binary
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
