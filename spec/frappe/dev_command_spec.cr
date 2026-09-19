require "spec"
require "../../src/frappe/dev_command"

describe Caramel::Frappe::DevCommand::Output do
  it "drops a partially retained diagnostic line instead of exposing a fragment of its secret" do
    capture = Caramel::Frappe::DevCommand::Output.new
    capture << ("b" * 64 + "\n" + "a" * 32700 + "\nA complete diagnostic\n")
    capture.contents.includes?("b" * 8).should be_false
    capture.contents.should contain("A complete diagnostic")
  end
end
