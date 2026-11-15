require "spec"
require "./support/shard_project"
require "../../src/frappe/shard_commands"

private BUILTIN = Caramel::Frappe::Commands.builtin

private def load(root : String) : Caramel::Frappe::ShardCommands::Loaded
  Caramel::Frappe::ShardCommands.load(root)
end

# The one problem reported for a project whose demo shard has *manifest*, which
# contributes nothing.
private def problem(manifest : String) : Caramel::Frappe::ShardCommands::Problem
  ShardProject.create({"demo" => manifest}) do |root|
    loaded = load(root)
    loaded.table.should be(BUILTIN)
    loaded.problems.size.should eq(1)
    loaded.problems.first
  end
end

# The rule broken by a manifest of *entries* and *families* that names *tool*.
private def rule(entries : Array(Hash(String, String | Array(String))),
                 families : Hash(String, String) = {} of String => String,
                 tool : String? = nil) : String
  problem(ShardProject.manifest(entries, families, tool: tool)).rule
end

private def entry(syntax : String, **fields) : Hash(String, String | Array(String))
  ShardProject.entry(syntax, **fields)
end

describe Caramel::Frappe::ShardCommands do
  it "adds a shard's commands after the built-ins, each under the shard's name" do
    ShardProject.create({"demo" => ShardProject.fixture}) do |root|
      loaded = load(root)
      loaded.problems.should be_empty
      table = loaded.table
      table.commands.first(BUILTIN.commands.size).should eq(BUILTIN.commands)
      contributed = table.contributed("demo")
      contributed.should eq(table.commands.last(5))
      contributed.map(&.syntax).should eq([
        "demo:greet NAME [--loud]", "demo:notes list", "demo:notes add TEXT",
        "demo:database", "demo:install NOTE [--agent|--human]",
      ])
      greet = contributed.first
      greet.brief.should eq("Greet someone by name")
      greet.examples.should eq(["demo:greet Ada", "demo:greet Ada --loud"])
      greet.project?.should be_true
      table.families["demo:notes"].should eq("List or add notes")
    end
  end

  it "gives each contributing shard one help group after the built-in groups" do
    ShardProject.create({"demo" => ShardProject.fixture}) do |root|
      groups = load(root).table.groups
      groups.first(BUILTIN.groups.size).should eq(BUILTIN.groups)
      group = groups.last
      names = ["demo:greet", "demo:notes", "demo:database", "demo:install"]
      {group.title, group.names}.should eq({"DEMO", names})
    end
  end

  it "parses an invocation of a contributed command against its syntax" do
    ShardProject.create({"demo" => ShardProject.fixture}) do |root|
      table = load(root).table
      greeting = table.parse(["demo:greet", "Ada", "--loud"])
      {greeting["NAME"], greeting.flag?("--loud")}.should eq({"Ada", true})
      table.parse(["demo:notes", "add", "Post the letter"])["TEXT"].should eq("Post the letter")
      missing = expect_raises(Caramel::Frappe::Commands::Usage) { table.parse(["demo:greet"]) }
      missing.message.should eq("missing NAME")
    end
  end

  it "adds shards in the order of their names" do
    manifests = {"zest" => [entry("peel")], "demo" => [entry("greet")], "apple" => [entry("core")]}
    written = manifests.transform_values { |entries| ShardProject.manifest(entries) }
    ShardProject.create(written) do |root|
      table = load(root).table
      table.shards.should eq(["apple", "demo", "zest"])
      table.commands.last(3).map(&.name).should eq(["apple:core", "demo:greet", "zest:peel"])
    end
  end

  it "reads only the shards that shard.lock locks" do
    ShardProject.create({"demo" => ShardProject.fixture}, locked: ["pg"]) do |root|
      loaded = load(root)
      loaded.table.should be(BUILTIN)
      loaded.problems.should be_empty
    end
  end

  it "skips a locked shard that lib/ does not hold, or that has no manifest" do
    ShardProject.create({"demo" => ShardProject.fixture}, locked: ["demo", "pg", "db"]) do |root|
      Dir.mkdir_p(File.join(root, "lib/pg"))
      loaded = load(root)
      loaded.table.shards.should eq(["demo"])
      loaded.problems.should be_empty
    end
  end

  it "answers the built-ins outside a project" do
    ShardProject.create({"demo" => ShardProject.fixture}) do |root|
      File.write(File.join(root, "shard.lock"), ShardProject.lock(["demo"]))
      load(root).table.should be(BUILTIN)
      File.delete(File.join(root, "shard.lock"))
      load(root).table.should be(BUILTIN)
    end
  end

  it "names the file, the rule and a one-line remedy for a refused manifest" do
    found = problem(ShardProject.manifest([entry("greet NAME", brief: nil)]))
    found.shard.should eq("demo")
    found.file.should eq("lib/demo/frappe.yml")
    found.rule.should eq(%(the command "greet NAME" has no brief))
    found.remedy.should eq("Add brief: with one line of text to the command.")
    found.message.should eq(<<-TEXT)
      lib/demo/frappe.yml: the command "greet NAME" has no brief. \
      Frappé did not load the demo shard's commands.
      Add brief: with one line of text to the command.
      TEXT
  end

  it "refuses a newer format, naming the format it reads" do
    newer = problem(ShardProject.manifest([entry("greet")], format: 2))
    newer.file.should eq("lib/demo/frappe.yml")
    newer.rule.should eq("the manifest is format 2, and this Frappé reads format 1")
    newer.remedy.should start_with("Run the Caramel release the shard is written for")
    older = problem(ShardProject.manifest([entry("greet")], format: 0))
    older.rule.should eq("the manifest is format 0, and this Frappé reads format 1")
    older.remedy.should eq("Write format: 1.")
  end

  it "refuses a malformed manifest" do
    problem("format: 1\ncommands: [").rule.should start_with("the manifest is malformed: ")
    unknown = problem("format: 1\ncommands: []\naliases: {}\n")
    unknown.rule.should start_with("the manifest is malformed: Unknown yaml attribute: aliases")
    problem("commands: []\n").rule.should eq("the manifest names no format")
    problem("- greet\n").rule.should eq("the manifest names no format")
    problem("format: 1\n").rule.should eq("the manifest declares no command")
  end

  it "refuses a command without a brief or a description, or with one of several lines" do
    rule([entry("greet", brief: nil)]).should eq(%(the command "greet" has no brief))
    rule([entry("greet", brief: " ")]).should eq(%(the command "greet" has no brief))
    rule([entry("greet", description: nil)]).should eq(%(the command "greet" has no description))
    two_lines = %(the brief of the command "greet" takes more than one line)
    rule([entry("greet", brief: "Greet\nsomeone")]).should eq(two_lines)
    nameless = "format: 1\ncommands:\n  - brief: Greet\n"
    problem(nameless).rule.should eq("a command has no syntax")
  end

  it "refuses a command that is not named by a lowercase word" do
    ["Greet NAME", "NAME", "--loud", "demo:greet NAME", "9lives"].each do |syntax|
      expected = "the command #{syntax.inspect} does not start with a command word"
      rule([entry(syntax)]).should eq(expected)
    end
  end

  it "refuses a command that runs any way but as application or tool, naming the value" do
    expected = "the command \"greet\" runs as \"binary\", " \
               "and this Frappé runs a command as application or tool"
    rule([entry("greet", run: "binary")]).should eq(expected)
    rule([entry("greet", run: nil)]).should eq(%(the command "greet" does not say how it runs))
  end

  it "records how each command runs, and the program that runs a shard's tool commands" do
    ShardProject.create({"demo" => ShardProject.fixture}) do |root|
      loaded = load(root)
      runs = loaded.table.contributed("demo").to_h { |command| {command.name, command.run} }
      runs["demo:greet"].should eq(Caramel::Frappe::Commands::Run::Application)
      runs["demo:install"].should eq(Caramel::Frappe::Commands::Run::Tool)
      loaded.tools.should eq({"demo" => "src/demo/frappe.cr"})
      BUILTIN.commands.compact_map(&.run).should be_empty
    end
  end

  it "names no program for a shard whose commands all run as the application's" do
    ShardProject.create({"demo" => ShardProject.manifest([entry("greet")])}) do |root|
      loaded = load(root)
      loaded.problems.should be_empty
      loaded.tools.should be_empty
    end
  end

  it "refuses a tool command without a tool program, and a tool program without one" do
    unnamed = rule([entry("install", run: "tool")])
    unnamed.should eq("the command \"install\" runs as tool, " \
                      "and the manifest names no tool program")
    unused = rule([entry("greet")], tool: "src/demo/frappe.cr")
    unused.should eq("the manifest names the tool program \"src/demo/frappe.cr\", " \
                     "and no command runs as tool")
  end

  it "refuses a tool program that is not a Crystal file under the shard's src/" do
    install = [entry("install", run: "tool")]
    ["tools/frappe.cr", "src/frappe.rb", "/src/frappe.cr", "src/../../frappe.cr"].each do |path|
      expected = "the tool program #{path.inspect} is not a Crystal file under the shard's src/"
      rule(install, tool: path).should eq(expected)
    end
  end

  it "refuses a tool program that the shard does not ship" do
    install = [entry("install", run: "tool")]
    manifest = ShardProject.manifest(install, tool: "src/demo/frappe.cr")
    ShardProject.create({"demo" => manifest}) do |root|
      File.delete(File.join(root, "lib/demo/src/demo/frappe.cr"))
      found = load(root).problems.first
      found.rule.should eq(%(the tool program "src/demo/frappe.cr" is not a file of the shard))
      found.remedy.should eq("Ship the file with the shard, at that path.")
    end
  end

  it "refuses a tool program that is a link out of the shard" do
    install = [entry("install", run: "tool")]
    manifest = ShardProject.manifest(install, tool: "src/demo/frappe.cr")
    ShardProject.create({"demo" => manifest}) do |root|
      program = File.join(root, "lib/demo/src/demo/frappe.cr")
      File.delete(program)
      File.symlink(File.join(root, "shard.lock"), program)
      found = load(root).problems.first
      found.rule.should eq(%(the tool program "src/demo/frappe.cr" is not a file of the shard))
    end
  end

  it "reports a shard whose name cannot prefix a command, when it has a manifest" do
    manifests = {
      "9lives" => ShardProject.manifest([entry("purr")]),
      "demo"   => ShardProject.fixture,
    }
    ShardProject.create(manifests, locked: ["9lives", "demo", "Loud"]) do |root|
      Dir.mkdir_p(File.join(root, "lib/Loud"))
      loaded = load(root)
      loaded.table.shards.should eq(["demo"])
      loaded.problems.size.should eq(1)
      found = loaded.problems.first
      found.file.should eq("lib/9lives/frappe.yml")
      found.rule.should eq(%(the shard's name, "9lives", cannot prefix a command))
      found.remedy.should start_with("Name the shard with a lowercase letter")
      found.message.should contain("Frappé did not load the 9lives shard's commands.")
    end
  end

  it "refuses a command declared twice" do
    twice = rule([entry("greet NAME"), entry("greet [--loud]")])
    twice.should eq(%(the command "greet" is declared twice))
  end

  it "refuses a run of words that begins a longer command without its line" do
    notes = [entry("notes list"), entry("notes add TEXT", examples: ["notes add Tea"])]
    rule(notes).should eq(%(commands start with "notes", and families has no line for it))
    rule(notes, {"notes" => " "}).should eq(%(the family "notes" has no line))
    stray = rule(notes, {"notes" => "List or add notes", "greet" => "Greet"})
    stray.should eq(%(families has a line for "greet", which starts no longer command))
  end

  it "refuses an example that does not parse as its command" do
    declared = %(does not parse as the command "greet NAME")
    missing = rule([entry("greet NAME", examples: ["greet"])])
    missing.should eq(%(the example "greet" #{declared}: missing NAME))
    other = rule([entry("greet NAME", examples: ["wave Ada"]), entry("wave NAME")])
    other.should eq(%(the example "wave Ada" #{declared}: it is demo:wave))
    prefixed = rule([entry("greet NAME", examples: ["demo:greet Ada"])])
    prefixed.should start_with(%(the example "demo:greet Ada" #{declared}: unknown command))
  end

  it "keeps the built-ins and the other shards beside a refused manifest" do
    manifests = {
      "broken" => ShardProject.manifest([entry("greet", brief: nil)]),
      "demo"   => ShardProject.fixture,
    }
    ShardProject.create(manifests) do |root|
      loaded = load(root)
      loaded.problems.map(&.file).should eq(["lib/broken/frappe.yml"])
      loaded.table.shards.should eq(["demo"])
      loaded.table.commands.first(BUILTIN.commands.size).should eq(BUILTIN.commands)
      loaded.table.parse(["routes", "books"])["FILTER"].should eq("books")
    end
  end
end
