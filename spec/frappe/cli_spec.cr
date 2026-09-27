require "spec"
require "file_utils"
require "../../src/frappe/cli"

describe Caramel::Frappe::CLI do
  it "shows help and the version without touching a toolchain or service" do
    output, errors = IO::Memory.new, IO::Memory.new
    cli = Caramel::Frappe::CLI.new("/missing-framework", output, errors)
    cli.run(["--help"]).should eq(0)
    output.to_s.should contain("frappe new NAME")
    output.to_s.should contain("frappe make resource NAME")
    output.to_s.should contain("frappe dev [--no-open]")
    errors.to_s.should eq("")
    output.clear
    cli.run(["--version"]).should eq(0)
    output.to_s.should eq("Frappé #{Caramel::VERSION}\n")
  end

  it "returns a usage error with a close command suggestion" do
    output, errors = IO::Memory.new, IO::Memory.new
    cli = Caramel::Frappe::CLI.new("/missing-framework", output, errors)
    cli.run(["migrte"]).should eq(2)
    errors.to_s.should contain("Did you mean migrate?")
    cli.run(["new"]).should eq(2)
    errors.to_s.should contain("frappe new NAME")
    cli.run(["make", "resource"]).should eq(2)
  end

  it "describes the database, logs, sites and installation commands and rejects malformed arguments" do
    output, errors = IO::Memory.new, IO::Memory.new
    cli = Caramel::Frappe::CLI.new("/missing-framework", output, errors)
    cli.run(["--help"]).should eq(0)
    usages = [
      "frappe db dump | frappe db restore FILE | frappe db diff --name NAME [--dev-override]",
      "frappe logs [app|compiler] [--follow]",
      "frappe sites [remove NAME]",
      "frappe installations [list|register|remove VERSION]",
      "frappe migrate [--dev-override]",
    ]
    usages.each { |usage| output.to_s.should contain(usage) }
    {["db"] => usages[0], ["db", "restore"] => usages[0], ["db", "diff"] => usages[0], ["db", "diff", "--name"] => usages[0],
     ["db", "diff", "--name", "a", "--force"] => usages[0], ["logs", "bogus"] => usages[1],
     ["sites", "remove"] => usages[2], ["installations", "remove"] => usages[3], ["migrate", "--force"] => usages[4],
     ["migrate", "--dev-override", "--dev-override"] => usages[4]}.each do |arguments, usage|
      errors.clear
      cli.run(arguments).should eq(2)
      errors.to_s.should contain(usage)
    end
  end

  it "routes frappe lsp to a known server only after the project version check" do
    output, errors = IO::Memory.new, IO::Memory.new
    cli = Caramel::Frappe::CLI.new(File.expand_path("../..", __DIR__), output, errors)
    cli.run(["--help"]).should eq(0)
    output.to_s.should contain("frappe lsp crystalline|ameba-ls")
    cli.run(["lsp"]).should eq(2)
    errors.to_s.should contain("frappe lsp crystalline|ameba-ls")
    errors.clear
    cli.run(["lsp", "liger"]).should eq(2)
    errors.to_s.should contain("frappe lsp crystalline|ameba-ls")
    errors.clear
    project = File.tempname("caramel-lsp-project-")
    Dir.mkdir(project)
    begin
      File.write(File.join(project, ".caramel-version"), "0.0.0\n")
      Dir.cd(project) { cli.run(["lsp", "ameba-ls"]) }.should eq(1)
      errors.to_s.should contain("Project framework version differs from Frappé #{Caramel::VERSION}; use its matching Caramel installation")
    ensure
      FileUtils.rm_rf(project)
    end
  end
end
