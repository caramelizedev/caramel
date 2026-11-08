require "spec"
require "../../src/frappe/help"

# An output that claims to be a terminal.
private class TerminalMemory < IO::Memory
  def tty? : Bool
    true
  end
end

describe Caramel::Frappe::Help do
  table = Caramel::Frappe::Commands::TABLE
  families = Caramel::Frappe::Commands::FAMILIES

  it "keeps every page within 80 columns" do
    Caramel::Frappe::Help.overview(false).lines.max_of(&.size).should be <= 80
    table.each do |command|
      Caramel::Frappe::Help.command(command, false).lines.max_of(&.size).should be <= 80
    end
    families.each_key do |key|
      Caramel::Frappe::Help.family(key.split(' '), false).lines.max_of(&.size).should be <= 80
    end
  end

  it "bolds headings only on a colour terminal" do
    Caramel::Frappe::Help.overview(false).should_not contain("\e")
    Caramel::Frappe::Help.overview(true).should contain("\e[1mUSAGE\e[0m\n")
  end

  it "prints a command's syntax, wrapped without splitting a token" do
    command = table.find!(&.name.==("make resource"))
    page = Caramel::Frappe::Help.command(command, false)
    usage = page.lines.skip_while { |line| line != "USAGE" }.skip(1)
    usage = usage.take_while { |line| !line.empty? }
    usage.size.should be > 1
    usage.map(&.strip).join(' ').should eq("frappe #{command.syntax}")
  end

  it "lists a family root's subcommands after its own usage" do
    command = table.find!(&.name.==("lsp"))
    page = Caramel::Frappe::Help.command(command, false)
    page.should contain("  frappe lsp crystalline|ameba-ls [SERVER_ARGS...]\n")
    page.should contain("\nCOMMANDS\n  lsp install  ")
    Caramel::Frappe::Help.command(table.find!(&.name.==("format")), false)
      .should_not contain("COMMANDS")
  end

  it "colours only a terminal, unless NO_COLOR is set or TERM is dumb" do
    terminal = TerminalMemory.new
    color = ->(environment : Hash(String, String)) do
      Caramel::Frappe::Terminal.color?(terminal, environment)
    end
    color.call({"TERM" => "xterm"}).should be_true
    color.call({} of String => String).should be_true
    color.call({"NO_COLOR" => ""}).should be_true
    color.call({"NO_COLOR" => "1"}).should be_false
    color.call({"TERM" => "dumb"}).should be_false
    Caramel::Frappe::Terminal.color?(IO::Memory.new, {"TERM" => "xterm"}).should be_false
  end
end
