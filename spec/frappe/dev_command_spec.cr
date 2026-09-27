require "spec"
require "../../src/frappe/dev_command"

describe Caramel::Frappe::DevCommand::Output do
  it "drops a partially retained diagnostic line instead of exposing a fragment of its secret" do
    capture = Caramel::Frappe::DevCommand::Output.new
    capture << ("b" * 64 + "\n" + "a" * 32700 + "\nA complete diagnostic\n")
    capture.contents.includes?("b" * 8).should be_false
    capture.contents.should contain("A complete diagnostic")
  end

  it "tees every output byte to the log while retaining only complete bounded diagnostics" do
    log = IO::Memory.new
    capture = Caramel::Frappe::DevCommand::Output.new(nil, log)
    payload = "a" * 33_000 + "\nLast diagnostic\n"
    capture.write(payload.to_slice)
    capture.write("next\n".to_slice)
    log.to_s.should eq(payload + "next\n")
    capture.contents.bytesize.should be <= 32_768
    capture.contents.should contain("Last diagnostic\nnext\n")
  end
end
