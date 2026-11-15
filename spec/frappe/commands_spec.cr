require "spec"
require "../../src/frappe/commands"
require "../../src/frappe/help"
require "../../src/frappe/completion"

private def parse(*args : String) : Caramel::Frappe::Commands::Invocation
  Caramel::Frappe::Commands.builtin.parse(args.to_a)
end

private MIGRATE = "frappe migrate [--dev-override] [--agent|--human]"

private def refusal(*args : String) : Caramel::Frappe::Commands::Usage
  expect_raises(Caramel::Frappe::Commands::Usage) do
    Caramel::Frappe::Commands.builtin.parse(args.to_a)
  end
end

private GREET_SYNTAX = "demo:greet NAME [--loud] [--times=1..3]"
private GREET        = Caramel::Frappe::Commands::Command.new(GREET_SYNTAX, "Greet NAME.",
  brief: "Greet someone")

# The built-ins and the one command a shard named demo contributes.
private def extended : Caramel::Frappe::Commands::Table
  builtin = Caramel::Frappe::Commands.builtin
  groups = builtin.groups + [Caramel::Frappe::Commands::Group.new("DEMO", ["demo:greet"])]
  Caramel::Frappe::Commands::Table.new(builtin.commands + [GREET], builtin.families, groups)
end

# The error *table* raises for *args*.
private def refused(table : Caramel::Frappe::Commands::Table,
                    *args : String) : Caramel::Frappe::Commands::Usage
  expect_raises(Caramel::Frappe::Commands::Usage) { table.parse(args.to_a) }
end

# The commands with *syntaxes*, each with a description and a brief.
private def commands_of(syntaxes : Array(String)) : Array(Caramel::Frappe::Commands::Command)
  syntaxes.map do |syntax|
    Caramel::Frappe::Commands::Command.new(syntax, "Does it.", brief: "Do it")
  end
end

# A table of the commands with *syntaxes* and the lines *families*, with one help group
# that lists every first word once.
private def table_of(syntaxes : Array(String),
                     families = {} of String => String) : Caramel::Frappe::Commands::Table
  commands = commands_of(syntaxes)
  group = Caramel::Frappe::Commands::Group.new("GROUP", commands.map(&.words.first).uniq!)
  Caramel::Frappe::Commands::Table.new(commands, families, [group])
end

describe Caramel::Frappe::Commands do
  it "binds positionals, choices, repeated values and every option form" do
    dev = parse("dev", "--branch", "feature_x", "--no-open")
    dev.command.name.should eq("dev")
    dev["--branch"].should eq("feature_x")
    dev.flag?("--no-open").should be_true
    parse("dev").flag?("--no-open").should be_false
    parse("setup", "--no-migrate").flag?("--no-migrate").should be_true
    parse("setup").flag?("--no-migrate").should be_false

    make = parse("make", "resource", "Person", "name:string", "age:int32", "--plural=people")
    make.command.name.should eq("make resource")
    bound = {make["NAME"], make.list("FIELD:TYPE"), make["--plural"]}
    bound.should eq({"Person", ["name:string", "age:int32"], "people"})

    parse("db", "branch", "create", "feature_x")["NAME"].should eq("feature_x")
    parse("db", "diff", "--dev-override", "--name", "add_isbn")["--name"].should eq("add_isbn")
    parse("logs", "compiler", "--follow")["app|compiler|access"].should eq("compiler")
    parse("logs", "access")["app|compiler|access"].should eq("access")
    parse("routes")["FILTER"]?.should be_nil
    parse("routes", "books")["FILTER"].should eq("books")
    corretto = parse("corretto", "spec/models", "spec/requests", "--concurrency=8")
    corretto.list("SPEC_PATHS").should eq(["spec/models", "spec/requests"])
    parse("sites", "remove", "shelf").command.name.should eq("sites remove")
    parse("sites").command.name.should eq("sites")
    parse("installations", "list").command.name.should eq("installations")
  end

  it "passes language-server arguments through verbatim, flags included" do
    server = parse("lsp", "ameba-ls", "--stdio", "--version")
    bound = {server["crystalline|ameba-ls"], server.list("SERVER_ARGS")}
    bound.should eq({"ameba-ls", ["--stdio", "--version"]})
    parse("lsp", "install").command.name.should eq("lsp install")
  end

  it "refuses malformed arguments with the intended command's exact syntax" do
    # Each command's syntax, and the message each malformed invocation of it gets.
    refusals = {
      "frappe new NAME" => {
        %w[new] => "missing NAME",
      },
      "frappe check [--agent|--human]" => {
        %w[check --agent --human] => "--agent and --human exclude each other",
      },
      MIGRATE => {
        %w[migrate --dev-override --dev-override] => "--dev-override is given more than once",
      },
      "frappe corretto [SPEC_PATHS...] [--concurrency=1..8]" => {
        %w[corretto --concurrency=9]  => "--concurrency must be a whole number from 1 to 8",
        %w[corretto --concurrency=+2] => "--concurrency must be a whole number from 1 to 8",
        %w[corretto --concurrency]    => "--concurrency needs a value: --concurrency=1..8",
        ["corretto", ""]              => "empty argument for SPEC_PATHS",
      },
      "frappe setup [--no-migrate]" => {
        %w[setup --no-migrate --no-migrate] => "--no-migrate is given more than once",
        %w[setup --no-migrate=1]            => "--no-migrate takes no value",
      },
      "frappe dev [--no-open] [--branch NAME]" => {
        %w[dev --branch]      => "--branch needs a value: --branch NAME",
        %w[dev --branch=x]    => "--branch needs a value: --branch NAME",
        %w[dev --no-open=yes] => "--no-open takes no value",
      },
      "frappe db diff --name NAME [--dev-override] [--agent|--human]" => {
        %w[db diff --name] => "--name needs a value: --name NAME",
        %w[db diff]        => "missing --name NAME",
      },
      "frappe db restore FILE" => {
        %w[db restore] => "missing FILE",
      },
      "frappe routes [FILTER]" => {
        %w[routes a b] => "unexpected argument \"b\"",
      },
      "frappe expand FILE:LINE:COL" => {
        %w[expand] => "missing FILE:LINE:COL",
      },
      "frappe make resource NAME FIELD:TYPE... [--plural=NAME] [--only=ACTIONS] " \
      "[--central] [--int64]" => {
        %w[make resource Book] => "missing FIELD:TYPE",
      },
    }
    refusals.each do |syntax, messages|
      messages.each do |arguments, message|
        error = expect_raises(Caramel::Frappe::Commands::Usage) do
          Caramel::Frappe::Commands.builtin.parse(arguments)
        end
        {error.message, error.syntax}.should eq({message, syntax})
      end
    end
  end

  it "suggests the nearest command, subcommand, choice or option" do
    unknown = refusal("migrte")
    expected = {"unknown command migrte", "migrate", MIGRATE}
    {unknown.message, unknown.suggestion, unknown.syntax}.should eq(expected)
    refusal("setup", "--no-migrat").suggestion.should eq("--no-migrate")
    refusal("dev", "--branc", "x").suggestion.should eq("--branch")
    refusal("check", "--agnet").suggestion.should eq("--agent")
    refusal("logs", "complier").suggestion.should eq("compiler")
    branch = refusal("db", "branch", "craete", "x")
    {branch.message, branch.suggestion}.should eq({"unknown db branch subcommand craete", "create"})
    branch_syntax = "frappe db branch create NAME | frappe db branch list | " \
                    "frappe db branch delete NAME"
    branch.syntax.should eq(branch_syntax)
    refusal("db", "brnach").suggestion.should eq("branch")
    refusal("sites", "remvoe").suggestion.should eq("remove")
    nothing = refusal("zzzzzz")
    {nothing.suggestion, nothing.syntax}.should eq({nil, nil})
    lsp_syntax = "frappe lsp crystalline|ameba-ls [SERVER_ARGS...] | frappe lsp install"
    refusal("lsp").syntax.should eq(lsp_syntax)
    refusal("db").message.should eq("frappe db needs a subcommand")
  end

  it "knows which invocations belong to a project" do
    builtin = Caramel::Frappe::Commands.builtin
    builtin.project?(["lsp", "crystalline"]).should be_true
    builtin.project?(["lsp", "install"]).should be_false
    builtin.project?(["sites", "remove", "x"]).should be_false
    builtin.project?(["db"]).should be_true
    builtin.project?(["bogus"]).should be_false
    branches = ["db branch create", "db branch list", "db branch delete"]
    builtin.matching(["db", "branch"]).map(&.name).should eq(branches)
  end

  it "refuses a table that declares a command twice" do
    expect_raises(ArgumentError, "command table: brew is declared twice") do
      table_of(["brew", "brew NAME"])
    end
  end

  it "refuses a table whose first words are not each in exactly one help group" do
    commands = commands_of(["brew", "pour"])
    group = ->(names : Array(String)) { Caramel::Frappe::Commands::Group.new("GROUP", names) }
    groupings = [
      {[group.call(["brew"])], "pour is in no help group"},
      {[group.call(["brew", "pour", "serve"])], "help lists serve, no command's word"},
      {[group.call(["brew", "pour"]), group.call(["brew"])], "brew is listed twice in help"},
    ]
    groupings.each do |groups, message|
      expect_raises(ArgumentError, "command table: #{message}") do
        Caramel::Frappe::Commands::Table.new(commands, {} of String => String, groups)
      end
    end
  end

  it "refuses a run of words that begins a command without its line, and any other line" do
    notes = ["notes list", "notes add TEXT"]
    expect_raises(ArgumentError, "command table: notes begins a command and has no line") do
      table_of(notes)
    end
    expect_raises(ArgumentError, "command table: brew has a line and begins no command") do
      table_of(notes + ["brew"], {"notes" => "List or add notes", "brew" => "Brew"})
    end
    lined = table_of(notes, {"notes" => "List or add notes"})
    lined.brief(["notes"]).should eq("List or add notes")
  end

  it "gives every command a brief and examples that parse as it" do
    commands = Caramel::Frappe::Commands.builtin
    Caramel::Frappe::Commands::TABLE.each do |command|
      command.brief.should_not be_empty
      command.brief.size.should be <= 54
      command.brief.should_not end_with('.')
      unless command.flags.empty? && command.positionals.empty?
        command.examples.should_not be_empty
      end
      command.examples.each do |example|
        commands.parse(Process.parse_arguments_posix(example)).command.should be(command)
      end
    end
    Caramel::Frappe::Help::EXAMPLES.each do |example|
      commands.parse(Process.parse_arguments_posix(example))
    end
  end

  it "finds the words a help request names" do
    commands = Caramel::Frappe::Commands.builtin
    commands.help_words(%w[db branch create extra]).should eq(%w[db branch create])
    commands.help_words(%w[db bogus]).should eq(%w[db])
    commands.help_words(%w[bogus db]).should be_nil
    prefix = ->(words : Array(String)) do
      Caramel::Frappe::Commands.prefix(commands.matching(words))
    end
    prefix.call(%w[db branch]).should eq(%w[db branch])
    prefix.call(%w[db]).should eq(%w[db])
  end

  it "keeps the colon out of every built-in command's first word" do
    firsts = Caramel::Frappe::Commands::TABLE.map(&.words.first)
    firsts.select(&.includes?(':')).should be_empty
  end

  it "parses a namespaced command with its positionals and flags" do
    greeting = extended.parse(["demo:greet", "Ada", "--loud", "--times=2"])
    greeting.command.should be(GREET)
    GREET.words.should eq(["demo:greet"])
    bound = {greeting["NAME"], greeting.flag?("--loud"), greeting["--times"]}
    bound.should eq({"Ada", true, "2"})
    missing = refused(extended, "demo:greet")
    {missing.message, missing.syntax}.should eq({"missing NAME", "frappe #{GREET_SYNTAX}"})
    refused(extended, "demo:greet", "Ada", "--lod").suggestion.should eq("--loud")
  end

  it "lists, suggests and matches a namespaced command like any other" do
    table = extended
    table.matching(["demo:greet"]).should eq([GREET])
    table.brief(["demo:greet"]).should eq("Greet someone")
    table.help_words(["demo:greet", "Ada"]).should eq(["demo:greet"])
    mistyped = refused(table, "demo:gret", "Ada")
    suggested = {mistyped.suggestion, mistyped.syntax}
    suggested.should eq({"demo:greet", "frappe #{GREET_SYNTAX}"})
    overview = Caramel::Frappe::Help.overview(table, false)
    overview.should contain("\nDEMO\n  demo:greet      Greet someone\n")
    roots = Caramel::Frappe::Completion.nodes(table)[""].map(&.word)
    roots.last.should eq("demo:greet")
    Caramel::Frappe::Completion.nodes(table)["demo:greet"].map(&.word)
      .should eq(["--loud", "--times="])
  end

  it "refuses an unknown namespaced word as it does any unknown command" do
    absent = refused(Caramel::Frappe::Commands.builtin, "something:else")
    found = {absent.message, absent.subject, absent.suggestion, absent.syntax}
    found.should eq({"unknown command something:else", "frappe something:else", nil, nil})
    other = refused(extended, "demo:other", "Ada")
    {other.message, other.subject}.should eq({"unknown command demo:other", "frappe demo:other"})
  end

  it "counts a first word with a colon as a project invocation, in the table or not" do
    builtin = Caramel::Frappe::Commands.builtin
    extended.project?(["demo:greet", "Ada"]).should be_true
    builtin.project?(["demo:greet", "Ada"]).should be_true
    extended.project?(["other:thing"]).should be_true
    builtin.project?(["something:else"]).should be_true
  end

  it "refuses a malformed namespaced word when the command is defined" do
    malformed = ["Demo:greet", "demo:Greet", ":greet", "demo:", "demo:greet:x", "demo::greet"]
    malformed.each do |word|
      refused(extended, word, "Ada").message.should eq("unknown command #{word}")
      expect_raises(ArgumentError, "must start with a word") do
        Caramel::Frappe::Commands::Command.new("#{word} NAME", "Greet NAME.", brief: "Greet")
      end
    end
  end
end
