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

# A `--stats` stage as Crystal 1.21 prints it: the padded name and a carriage
# return when the stage starts, then the name with its time and memory.
private def stage(name : String) : String
  label = "#{name}:".ljust(34)
  "#{label}\r#{label} 00:00:00.000556250 ( 179.33MB)\n"
end

describe Caramel::Frappe::DevCommand::Stages do
  it "passes a macro's output on, drops the stats, and signals once the type check passes" do
    output = Caramel::Frappe::DevCommand::Output.new
    passed = Channel(Nil).new
    stages = Caramel::Frappe::DevCommand::Stages.new(output, passed)
    top = "Semantic (top level):".ljust(34)
    semantic = ["new", "type declarations", "abstract def check", "restrictions augmenter",
                "ivars initializers", "cvars initializers", "main", "cleanup"]
    last = "Semantic (recursive struct check):"
    before = stage("Parse") + "#{top}\rmacro says hi\n#{top} 00:00:00.225252375 ( 131.33MB)\n" +
             semantic.join { |name| stage("Semantic (#{name})") } + "#{last}\rprinted meanwhile\n"
    # A pipe may split a line anywhere.
    stages.write(before[0, 50].to_slice)
    stages.write(before[50..].to_slice)
    stages.checked?.should be_false
    stages.write("#{last} 00:00:00.000556250 ( 179.33MB)\n".to_slice)
    stages.checked?.should be_true
    passed.closed?.should be_true
    report = "\nCodegen (bc+obj):\n - 3/4 .o files were reused\n\n" \
             "These modules were not reused:\n - App (_main.bc)\n"
    codegen = ["Codegen (crystal)", "Codegen (bc+obj)", "Codegen (linking)", "dsymutil"]
    stages.write((codegen.join { |name| stage(name) } + report).to_slice)
    output.contents.should eq("macro says hi\nprinted meanwhile\n")
  end
end
