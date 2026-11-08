require "spec"
require "file_utils"
require "../../src/frappe/cli"

private def cli(root = "/missing-framework") : {Caramel::Frappe::CLI, IO::Memory, IO::Memory}
  output, errors = IO::Memory.new, IO::Memory.new
  {Caramel::Frappe::CLI.new(root, output, errors), output, errors}
end

# The lines of a route listing that match *filter*.
private def filtered(listing : String, filter : String) : Array(String)
  Caramel::Frappe::CLI.filter_routes(listing, filter).lines
end

describe Caramel::Frappe::CLI do
  it "shows help, per-command usage and the version without touching a toolchain or service" do
    commands = Caramel::Frappe::Commands
    groups = Caramel::Frappe::Commands::GROUPS
    frappe, output, errors = cli
    frappe.run(["--help"]).should eq(0)
    help = output.to_s
    groups.each do |group|
      help.should contain("\n#{group.title}\n")
      group.names.each do |name|
        row = help.lines.find(&.starts_with?("  #{name} "))
        row.try(&.ends_with?(commands.brief([name]))).should be_true
      end
    end
    errors.to_s.should eq("")
    output.clear
    frappe.run(["help", "db", "branch"]).should eq(0)
    family = output.to_s
    output.clear
    frappe.run(["db", "branch", "--help"]).should eq(0)
    output.to_s.should eq(family)
    rows = family.lines.select(&.starts_with?("  db branch ")).map { |line| line.split("  ")[1] }
    rows.should eq(["db branch create", "db branch list", "db branch delete"])
    output.clear
    frappe.run(["dev", "--branch", "x", "--help"]).should eq(0)
    page = output.to_s
    output.clear
    frappe.run(["help", "dev"]).should eq(0)
    output.to_s.should eq(page)
    page.should contain("  frappe dev [--no-open] [--branch NAME]\n")
    page.should contain("  $ frappe dev --branch spike\n")
    output.clear
    frappe.run(["format", "--help"]).should eq(0)
    output.to_s.should_not contain("EXAMPLES")
    output.clear
    frappe.run(["lsp", "--help"]).should eq(0)
    output.to_s.should contain("  frappe lsp crystalline|ameba-ls [SERVER_ARGS...]\n")
    output.clear
    frappe.run(["--version"]).should eq(0)
    output.to_s.should eq("Frappé #{Caramel::VERSION}\n")
  end

  it "prints the strict manifest, one line per command, then the MRDP grammar" do
    frappe, output, errors = cli
    frappe.run(["agent-manifest"]).should eq(0)
    lines = output.to_s.lines
    lines.first.should eq("CARAMEL CLI INTERFACE (STRICT TOKENS)")
    docs = "DOCS: https://github.com/caramelizedev/caramel/tree/v#{Caramel::VERSION}"
    guides = "GUIDES: https://caramelize.dev/docs/#{Caramel::VERSION}/llms.txt"
    lines[1, 3].should eq(["VERSION: #{Caramel::VERSION}", docs, guides])
    commands = lines[4...lines.index!("")]
    table = Caramel::Frappe::Commands::TABLE.map do |command|
      "frappe #{command.syntax}  # #{command.summary}"
    end
    commands.should eq(table)
    %w[check routes expand dev corretto].each do |name|
      commands.any?(&.starts_with?("frappe #{name} ")).should be_true
    end
    branch_create = "frappe db branch create NAME  # Clone the development database " \
                    "into branch NAME and print its connection URL."
    commands.should contain(branch_create)
    grammar = lines[(commands.size + 4)..]
    patch = "PATCH: INSERT \"<text>\" AT <line>:<col>  # insert <text> as a new line " \
            "before <line> of the ERR file, indented to <col>"
    grammar.should contain(patch)
    codes = "CODES: CONTRACT_MISMATCH N_PLUS_ONE NULLABLE_WHERE"
    grammar.any?(&.starts_with?(codes)).should be_true
    errors.to_s.should eq("")
  end

  it "exits 1 for unknown commands and malformed arguments, as MRDP unless --human" do
    frappe, output, errors = cli
    frappe.run(["migrte"]).should eq(1)
    errors.to_s.should eq(<<-MRDP)
      ERR USAGE at frappe migrte
      MSG: unknown command migrte
      SYNTAX: frappe migrate [--dev-override] [--agent|--human]
      SUGGEST: migrate\n
      MRDP
    errors.clear
    frappe.run(["routes", "--verbose", "--human"]).should eq(1)
    errors.to_s.should contain("Usage: frappe routes [FILTER]")
    errors.clear
    frappe.run(["dev", "--branc", "x", "--human"]).should eq(1)
    errors.to_s.should contain("Usage: frappe dev [--no-open] [--branch NAME]")
    errors.to_s.should contain("Did you mean --branch?")
    errors.clear
    frappe.run(["florp", "--human"]).should eq(1)
    errors.to_s.should start_with("frappe florp: unknown command florp")
    output.to_s.should eq("")
    errors.clear
    frappe.run(["db", "--human"]).should eq(1)
    errors.to_s.should start_with("frappe db needs a subcommand.\n")
    errors.to_s.should contain("  db branch create ")
    output.to_s.should eq("")
    errors.clear
    frappe.run(["florp"]).should eq(1)
    errors.to_s.should eq(<<-MRDP)
      ERR USAGE at frappe florp
      MSG: unknown command florp
      FIX: frappe agent-manifest lists every command\n
      MRDP
    output.to_s.should eq("")
  end

  it "refuses an invalid branch name and a malformed expand location before loading a project" do
    frappe, _, errors = cli
    frappe.run(["db", "branch", "create", "Feature"]).should eq(1)
    errors.to_s.should eq(<<-MRDP)
      ERR USAGE at frappe db branch create
      MSG: branch name Feature must be a lowercase letter followed by up to 30 \
        lowercase letters, digits or underscores
      SYNTAX: frappe db branch create NAME\n
      MRDP
    errors.clear
    frappe.run(["expand", "config/routes.cr:2"]).should eq(1)
    errors.to_s.should eq(<<-MRDP)
      ERR USAGE at frappe expand
      MSG: config/routes.cr:2 is not FILE:LINE:COL
      SYNTAX: frappe expand FILE:LINE:COL\n
      MRDP
  end

  it "filters routes by method, path or action but not by contract" do
    listing = [
      "GET     /books/:id    App::Books::Show  id:Int64(min=1)\n",
      "PATCH   /books/:id    App::Books::Update  id:Int64(min=1) title:String\n",
      "POST    /people       App::People::Create  name:String\n",
    ].join
    filtered(listing, "patch").map(&.split.first).should eq(["PATCH"])
    filtered(listing, "/BOOKS").map(&.split.first).should eq(["GET", "PATCH"])
    filtered(listing, "people::create").map(&.split[1]).should eq(["/people"])
    Caramel::Frappe::CLI.filter_routes(listing, "title").should eq("")
  end

  it "routes frappe lsp to a known server only after the project version check" do
    frappe, _, errors = cli(File.expand_path("../..", __DIR__))
    syntax = "frappe lsp crystalline|ameba-ls [SERVER_ARGS...] | frappe lsp install"
    frappe.run(["lsp", "--human"]).should eq(1)
    errors.to_s.should contain("frappe lsp: unknown option --human")
    errors.to_s.should contain("  lsp install ")
    errors.clear
    frappe.run(["lsp", "liger"]).should eq(1)
    errors.to_s.should contain("SYNTAX: #{syntax}")
    errors.clear
    project = File.tempname("caramel-lsp-project-")
    Dir.mkdir(project)
    begin
      lock = <<-YAML
        version: 2.0
        shards:
          caramel:
            path: /private/tmp/caramel
            version: 0.0.0\n
        YAML
      File.write(File.join(project, "shard.lock"), lock)
      Dir.cd(project) { frappe.run(["lsp", "ameba-ls"]) }.should eq(1)
      refusal = "This project uses Caramel 0.0.0, not #{Caramel::VERSION}; " \
                "use its matching Caramel installation"
      errors.to_s.should contain(refusal)
    ensure
      FileUtils.rm_rf(project)
    end
  end
end
