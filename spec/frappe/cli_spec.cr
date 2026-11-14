require "spec"
require "file_utils"
require "./support/shard_project"
require "../../src/frappe/cli"

private def cli(root = "/missing-framework") : {Caramel::Frappe::CLI, IO::Memory, IO::Memory}
  output, errors = IO::Memory.new, IO::Memory.new
  {Caramel::Frappe::CLI.new(root, output, errors), output, errors}
end

# The lines of a route listing that match *filter*.
private def filtered(listing : String, filter : String) : Array(String)
  Caramel::Frappe::CLI.filter_routes(listing, filter).lines
end

# Runs frappe with *arguments* in a project whose demo shard has *manifest*, and
# returns its status, standard output and standard error.
private def in_project(arguments : Array(String),
                       manifest : String = ShardProject.fixture) : {Int32, String, String}
  frappe, output, errors = cli
  status = ShardProject.create({"demo" => manifest}) do |root|
    Dir.cd(root) { frappe.run(arguments) }
  end
  {status, output.to_s, errors.to_s}
end

# A manifest Frappé refuses: its one command has no brief.
private BRIEFLESS = ShardProject.manifest([ShardProject.entry("greet NAME", brief: nil)])
# What Frappé says about it.
private BRIEFLESS_PROBLEM = <<-TEXT
  lib/demo/frappe.yml: the command "greet NAME" has no brief. \
  Frappé did not load the demo shard's commands.
  Add brief: with one line of text to the command.\n
  TEXT

describe Caramel::Frappe::CLI do
  it "shows help, per-command usage and the version without touching a toolchain or service" do
    commands = Caramel::Frappe::Commands.builtin
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
    errors.clear
    frappe.run(["something:else"]).should eq(1)
    errors.to_s.should eq(<<-MRDP)
      ERR USAGE at frappe something:else
      MSG: unknown command something:else
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

  it "lists a contributing shard's group after the built-in groups in help" do
    status, help, errors = in_project(["help"])
    {status, errors}.should eq({0, ""})
    group = <<-TEXT

      DEMO
        demo:greet      Greet someone by name
        demo:notes      List or add notes\n
      TEXT
    help.should contain(group)
    help.index!(group).should be > help.index!("\nABOUT FRAPPÉ\n")
  end

  it "lists a shard's commands for frappe help SHARD" do
    status, page, errors = in_project(["help", "demo"])
    {status, errors}.should eq({0, ""})
    page.should eq(<<-TEXT)
      The commands the demo shard contributes.

      COMMANDS
        demo:greet       Greet someone by name
        demo:notes list  List the notes
        demo:notes add   Add a note

      LEARN MORE
        Use frappe help demo:greet for a command's usage and examples.\n
      TEXT
    in_project(["demo", "--help"]).should eq({0, page, ""})
  end

  it "shows a contributed command's usage and examples, and a contributed family's commands" do
    _, command, _ = in_project(["help", "demo:greet"])
    command.should start_with("Print a greeting for NAME; --loud prints it in capitals.\n")
    command.should contain("\nUSAGE\n  frappe demo:greet NAME [--loud]\n")
    examples = "\nEXAMPLES\n  $ frappe demo:greet Ada\n  $ frappe demo:greet Ada --loud\n"
    command.should contain(examples)
    command.should end_with("  Use frappe help demo for the demo shard's commands.\n")
    in_project(["demo:greet", "Ada", "--help"]).should eq({0, command, ""})
    _, family, _ = in_project(["help", "demo:notes"])
    family.should start_with("List or add notes.\n\nCOMMANDS\n  demo:notes list  List the notes\n")
  end

  it "lists contributed commands in the agent manifest, after the built-ins" do
    status, manifest, errors = in_project(["agent-manifest"])
    {status, errors}.should eq({0, ""})
    lines = manifest.lines
    commands = lines[4...lines.index!("")]
    builtin = Caramel::Frappe::Commands::TABLE.size
    commands[builtin..].should eq([
      "frappe demo:greet NAME [--loud]  # Print a greeting for NAME; " \
      "--loud prints it in capitals.",
      "frappe demo:notes list  # Print each note on its own line.",
      "frappe demo:notes add TEXT  # Add the note TEXT.",
    ])
  end

  it "validates a contributed command's arguments against its syntax before it builds" do
    status, output, errors = in_project(["demo:greet"])
    {status, output}.should eq({1, ""})
    errors.should eq(<<-MRDP)
      ERR USAGE at frappe demo:greet
      MSG: missing NAME
      SYNTAX: frappe demo:greet NAME [--loud]\n
      MRDP
    _, _, mistyped = in_project(["demo:gret", "Ada"])
    mistyped.should contain("SUGGEST: demo:greet\n")
  end

  it "shows none of a shard's commands outside a project" do
    directory = File.tempname("caramel-no-project-")
    Dir.mkdir_p(File.join(directory, "lib/demo"))
    begin
      File.write(File.join(directory, "lib/demo/frappe.yml"), ShardProject.fixture)
      frappe, output, errors = cli
      Dir.cd(directory) { frappe.run(["help"]) }.should eq(0)
      Dir.cd(directory) { frappe.run(["agent-manifest"]) }.should eq(0)
      output.to_s.should_not contain("demo:")
      errors.to_s.should eq("")
      Dir.cd(directory) { frappe.run(["demo:greet", "Ada", "--human"]) }.should eq(1)
      errors.to_s.should start_with("frappe demo:greet: unknown command demo:greet\n")
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "reports a refused manifest in help and the agent manifest, beside every built-in" do
    status, help, errors = in_project(["help"], BRIEFLESS)
    {status, errors}.should eq({0, BRIEFLESS_PROBLEM})
    help.should contain("\nGET STARTED\n")
    help.should_not contain("demo")
    status, manifest, errors = in_project(["agent-manifest"], BRIEFLESS)
    {status, errors}.should eq({0, BRIEFLESS_PROBLEM})
    manifest.should contain("\nfrappe routes [FILTER]  # ")
  end

  it "reports a refused manifest when its shard's commands are asked for" do
    asked = [["demo:greet", "Ada"], ["demo:greet", "--help"], ["help", "demo:greet"],
             ["help", "demo"], ["demo", "--help"]]
    asked.each do |arguments|
      in_project(arguments, BRIEFLESS).should eq({1, "", BRIEFLESS_PROBLEM})
    end
  end

  it "runs built-in commands beside a refused manifest without a word about it" do
    status, family, errors = in_project(["help", "db", "branch"], BRIEFLESS)
    {status, errors}.should eq({0, ""})
    family.should contain("  db branch create ")
    in_project(["version"], BRIEFLESS).should eq({0, "Frappé #{Caramel::VERSION}\n", ""})
    _, _, usage = in_project(["routes", "--verbose"], BRIEFLESS)
    usage.should eq(<<-MRDP)
      ERR USAGE at frappe routes
      MSG: unknown option --verbose
      SYNTAX: frappe routes [FILTER]\n
      MRDP
  end
end
