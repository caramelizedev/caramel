require "spec"
require "../../../src/caramel/crema/commands"

describe "Caramel::Crema.command" do
  it "runs a command named with a namespaced word, with the words after it" do
    Caramel::Crema.command("spec:greet", "spec:greet NAME") do |arguments|
      arguments == ["Ada"] ? 7 : 2
    end
    Caramel::Crema.run_command("spec:greet", ["Ada"]).should eq(7)
    Caramel::Crema.command_syntaxes.should contain("spec:greet NAME")
    Caramel::Crema.run_command("spec:absent", ["Ada"]).should be_nil
  end

  it "refuses a second registration of a name, naming the command" do
    Caramel::Crema.command("spec:once", "spec:once") { |_| 3 }
    expect_raises(ArgumentError, "The command spec:once is already registered") do
      Caramel::Crema.command("spec:once", "spec:once AGAIN") { |_| 4 }
    end
    Caramel::Crema.run_command("spec:once", [] of String).should eq(3)
    Caramel::Crema.command_syntaxes.should_not contain("spec:once AGAIN")
  end

  it "replaces a registration only when told to, as the recorder does for insights" do
    Caramel::Crema.command("spec:stub", "spec:stub") { |_| 1 }
    Caramel::Crema.command("spec:stub", "spec:stub [--since=DURATION]", replace: true) { |_| 0 }
    Caramel::Crema.run_command("spec:stub", [] of String).should eq(0)
    syntaxes = Caramel::Crema.command_syntaxes.select(&.starts_with?("spec:stub"))
    syntaxes.should eq(["spec:stub [--since=DURATION]"])
  end
end
