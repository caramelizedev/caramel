require "./project"
require "./tools"
require "./diagnostics"

module Caramel::Frappe
  # `frappe check` (RFC-0005 §2.2, Tier 1): type-checks the application's
  # main target with the development defines and no code generation. Without
  # --error-trace the compiler prints only the frame Diagnostics parses.
  class Check
    DEFINES = ["-D", "caramel_development"]

    def initialize(@project : Project, @tools : Tools, @output : IO)
    end

    def run(agent : Bool, color : Bool) : Int32
      entrypoint = @project.entrypoint
      compiler = IO::Memory.new
      status = Process.run(File.join(@tools.framework_root, "scripts/crystal"), ["build", entrypoint, "--no-codegen", *DEFINES],
        chdir: @project.root, env: @tools.environment, clear_env: true, input: Process::Redirect::Close, output: compiler, error: compiler)
      if status.success?
        if agent
          @output.puts("OK check #{files} files")
        else
          @output.puts(color ? "\e[1;32m✓ Type check passed\e[0m" : "✓ Type check passed")
        end
        return 0
      end
      Diagnostics.parse(compiler.to_s, @project.root, entrypoint).each_with_index do |diagnostic, index|
        if agent
          diagnostic.to_mrdp(@output)
        else
          @output.puts if index > 0
          diagnostic.render(@output, color)
        end
      end
      1
    end

    # The application's own Crystal sources and views that the main target compiles.
    private def files : Int32
      %w[app config db src].sum { |directory| Dir.glob(File.join(@project.root, directory, "**", "*.{cr,ecr}")).size }
    end
  end
end
