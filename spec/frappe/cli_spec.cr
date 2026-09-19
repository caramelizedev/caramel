require "spec"
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
end
