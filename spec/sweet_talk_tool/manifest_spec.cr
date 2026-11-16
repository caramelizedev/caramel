require "spec"
require "../frappe/support/shard_project"
require "../../src/frappe/shard_commands"
require "../../src/frappe/toolkit"
require "../../src/caramel/version"
require "../../sweettalk/src/sweettalk/tool/commands"

private SHARD    = File.expand_path("../../sweettalk", __DIR__)
private MANIFEST = File.read(File.join(SHARD, "frappe.yml"))

# The commands the shard's manifest contributes to a project that locks it.
private def contributed(&)
  ShardProject.create({"sweettalk" => MANIFEST}) do |root|
    loaded = Caramel::Frappe::ShardCommands.load(root)
    loaded.problems.map(&.message).should be_empty
    yield loaded.table.contributed("sweettalk"), loaded
  end
end

describe "sweettalk/frappe.yml" do
  it "declares the shard's five commands, two of them the tool program's" do
    contributed do |commands, loaded|
      commands.map(&.name).should eq([
        "sweettalk:words", "sweettalk:requirements", "sweettalk:glossary",
        "sweettalk:contexts", "sweettalk:make domain",
      ])
      tools = commands.select(&.run.try(&.tool?)).map(&.name)
      tools.should eq(["sweettalk:words", "sweettalk:make domain"])
      loaded.tools.should eq({"sweettalk" => "src/sweettalk/tool.cr"})
      File.file?(File.join(SHARD, loaded.tools["sweettalk"])).should be_true
    end
  end

  it "writes the syntax of sweettalk:words as the tool program prints it in a refusal" do
    contributed do |commands, _|
      words = commands.find!(&.name.==(SweetTalk::Tool::WORDS))
      words.syntax.should eq(SweetTalk::Tool::WORDS_SYNTAX)
    end
  end

  it "gives the tool program each tool command's words and options" do
    contributed do |commands, _|
      domain = commands.find!(&.name.==(SweetTalk::Tool::MAKE_DOMAIN))
      domain.syntax.should eq("sweettalk:make domain NAME CONTEXT --means=TEXT [--central]")
    end
  end
end
