require "./project"
require "./tools"
require "./diagnostics"

module Caramel::Frappe
  # `frappe check` (Tier 1): type-checks the application's
  # main target with the development defines and no code generation. Without
  # --error-trace the compiler prints only the frame Diagnostics parses.
  class Check
    DEFINES = ["-D", "caramel_development"]

    def initialize(@project : Project, @tools : Tools, @output : IO)
    end

    def run(agent : Bool, color : Bool) : Int32
      entrypoint = @project.entrypoint
      compiler = IO::Memory.new
      status = type_check(entrypoint, compiler)
      if status.success?
        if agent
          @output.puts("OK check #{files} files")
        else
          @output.puts(color ? "\e[1;32m✓ Type check passed\e[0m" : "✓ Type check passed")
        end
        return 0
      end
      diagnostics = Diagnostics.parse(compiler.to_s, @project.root, entrypoint)
      diagnostics.each_with_index do |diagnostic, index|
        if agent
          diagnostic.to_mrdp(@output)
        else
          @output.puts if index > 0
          diagnostic.render(@output, color)
        end
      end
      1
    end

    # Runs the compiler without code generation; *output* collects what it
    # prints on both streams.
    private def type_check(entrypoint : String, output : IO) : Process::Status
      crystal = File.join(@tools.framework_root, "scripts/crystal")
      Process.run(crystal, ["build", entrypoint, "--no-codegen", *DEFINES],
        chdir: @project.root,
        env: @tools.environment,
        clear_env: true,
        input: Process::Redirect::Close,
        output: output,
        error: output)
    end

    # The application's own Crystal sources and views that the main target compiles.
    private def files : Int32
      %w[app config db src].sum do |directory|
        Dir.glob(File.join(@project.root, directory, "**", "*.{cr,ecr}")).size
      end
    end
  end
end
