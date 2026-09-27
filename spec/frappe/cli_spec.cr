require "spec"
require "file_utils"
require "../../src/frappe/cli"

private def cli(root = "/missing-framework") : {Caramel::Frappe::CLI, IO::Memory, IO::Memory}
  output, errors = IO::Memory.new, IO::Memory.new
  {Caramel::Frappe::CLI.new(root, output, errors), output, errors}
end

describe Caramel::Frappe::CLI do
  it "shows help, per-command usage and the version without touching a toolchain or service" do
    frappe, output, errors = cli
    frappe.run(["--help"]).should eq(0)
    Caramel::Frappe::Commands::TABLE.each { |command| output.to_s.should contain("  frappe #{command.syntax}\n      #{command.description}\n") }
    errors.to_s.should eq("")
    output.clear
    frappe.run(["db", "branch", "--help"]).should eq(0)
    output.to_s.lines.select(&.starts_with?("Usage: ")).should eq(["Usage: frappe db branch create NAME", "Usage: frappe db branch list", "Usage: frappe db branch delete NAME"])
    output.clear
    frappe.run(["--version"]).should eq(0)
    output.to_s.should eq("Frappé #{Caramel::VERSION}\n")
  end

  it "prints the strict manifest, one line per command, then the MRDP grammar" do
    frappe, output, errors = cli
    frappe.run(["agent-manifest"]).should eq(0)
    lines = output.to_s.lines
    lines.first.should eq("CARAMEL CLI INTERFACE (STRICT TOKENS)")
    commands = lines[1...lines.index("").not_nil!]
    commands.should eq(Caramel::Frappe::Commands::TABLE.map { |command| "frappe #{command.syntax}  # #{command.description}" })
    %w(check routes expand dev corretto).each { |name| commands.any?(&.starts_with?("frappe #{name} ")).should be_true }
    commands.should contain("frappe db branch create NAME  # Clone the development database into branch NAME and print its connection URL.")
    grammar = lines[(commands.size + 2)..]
    grammar.should contain(%(PATCH: INSERT "<text>" AT <line>:<col>  # insert <text> as a new line before <line> of the ERR file, indented to <col>))
    grammar.any?(&.starts_with?("CODES: CONTRACT_MISMATCH N_PLUS_ONE")).should be_true
    errors.to_s.should eq("")
  end

  it "exits 1 for unknown commands and malformed arguments, as MRDP unless --human" do
    frappe, output, errors = cli
    frappe.run(["migrte"]).should eq(1)
    errors.to_s.should eq("ERR USAGE at frappe migrte\nMSG: unknown command migrte\nSYNTAX: frappe migrate [--dev-override] [--agent|--human]\nSUGGEST: migrate\n")
    errors.clear
    frappe.run(["routes", "--verbose", "--human"]).should eq(1)
    errors.to_s.should eq("frappe routes: unknown option --verbose\nUsage: frappe routes [FILTER]\n")
    errors.clear
    frappe.run(["dev", "--branc", "x", "--human"]).should eq(1)
    errors.to_s.should eq("frappe dev: unknown option --branc\nUsage: frappe dev [--no-open] [--branch NAME]\nDid you mean --branch?\n")
    errors.clear
    frappe.run(["florp", "--human"]).should eq(1)
    errors.to_s.should eq("frappe florp: unknown command florp\nUse frappe --help for available commands.\n")
    errors.clear
    frappe.run(["florp"]).should eq(1)
    errors.to_s.should eq("ERR USAGE at frappe florp\nMSG: unknown command florp\nFIX: frappe agent-manifest lists every command\n")
    output.to_s.should eq("")
  end

  it "refuses an invalid branch name and a malformed expand location before loading a project" do
    frappe, output, errors = cli
    frappe.run(["db", "branch", "create", "Feature"]).should eq(1)
    errors.to_s.should eq("ERR USAGE at frappe db branch create\nMSG: branch name Feature must be a lowercase letter followed by up to 30 lowercase letters, digits or underscores\nSYNTAX: frappe db branch create NAME\n")
    errors.clear
    frappe.run(["expand", "config/routes.cr:2"]).should eq(1)
    errors.to_s.should eq("ERR USAGE at frappe expand\nMSG: config/routes.cr:2 is not FILE:LINE:COL\nSYNTAX: frappe expand FILE:LINE:COL\n")
  end

  it "filters routes by method, path or action but not by contract" do
    listing = [
      "GET     /books/:id    App::Books::Show  id:Int64(min=1)\n",
      "PATCH   /books/:id    App::Books::Update  id:Int64(min=1) title:String\n",
      "POST    /people       App::People::Create  name:String\n",
    ].join
    Caramel::Frappe::CLI.filter_routes(listing, "patch").lines.map(&.split.first).should eq(["PATCH"])
    Caramel::Frappe::CLI.filter_routes(listing, "/BOOKS").lines.map(&.split.first).should eq(["GET", "PATCH"])
    Caramel::Frappe::CLI.filter_routes(listing, "people::create").lines.map(&.split[1]).should eq(["/people"])
    Caramel::Frappe::CLI.filter_routes(listing, "title").should eq("")
  end

  it "routes frappe lsp to a known server only after the project version check" do
    frappe, output, errors = cli(File.expand_path("../..", __DIR__))
    frappe.run(["lsp", "--human"]).should eq(1)
    errors.to_s.should contain("Usage: frappe lsp crystalline|ameba-ls [SERVER_ARGS...] | frappe lsp install")
    errors.clear
    frappe.run(["lsp", "liger"]).should eq(1)
    errors.to_s.should contain("SYNTAX: frappe lsp crystalline|ameba-ls [SERVER_ARGS...] | frappe lsp install")
    errors.clear
    project = File.tempname("caramel-lsp-project-")
    Dir.mkdir(project)
    begin
      File.write(File.join(project, ".caramel-version"), "0.0.0\n")
      Dir.cd(project) { frappe.run(["lsp", "ameba-ls"]) }.should eq(1)
      errors.to_s.should contain("Project framework version differs from Frappé #{Caramel::VERSION}; use its matching Caramel installation")
    ensure
      FileUtils.rm_rf(project)
    end
  end
end
