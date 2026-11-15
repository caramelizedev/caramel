require "spec"
require "file_utils"
require "../../src/frappe/toolkit"
require "../../src/caramel/version"
require "../../sweettalk/src/sweettalk/tool/commands"
require "../../sweettalk/src/sweettalk/tool/word_drift"

private REPO  = File.expand_path("../..", __DIR__)
private SHARD = File.join(REPO, "sweettalk")
private SKILL = "sweettalk/templates/SKILL.md"

# A SweetTalk source tree of one word, `thing`, and a refusal for it, as the macros write them.
private THING = <<-CRYSTAL
  module SweetTalk
    module BoundedContext
      # Prose for contributors, which `frappe sweettalk:words` ignores.
      #
      # @word noun | Declares a thing the glossary lists.
      # @usage thing NAME[, size: N], means: TEXT
      # @in in a context
      # @guide c-sweettalk-values
      # @option size | an integer | - | How many jars it holds.
      #   Zero is allowed.
      # @option means | text | - | What the thing is.
      # @example
      #   context Pantry, means: "what we keep" do
      #     thing Jar, size: 3, means: "a jar"
      #   end
      macro thing(name, size = nil, means = nil, &block)
        class {{ name }}
        end
      end
    end

    abstract class Model
      macro thing(name, size = nil, means = nil, &block)
        {% name.raise "thing belongs in a context" %}
      end
    end
  end
  CRYSTAL

# Loads the words of a shard whose source tree holds *source*.
private def vocabulary(source : String = THING) : SweetTalk::Tool::Words
  root = File.tempname("words-spec")
  directory = File.join(root, SweetTalk::Tool::Words::SOURCE)
  FileUtils.mkdir_p(directory)
  File.write(File.join(directory, "thing.cr"), source)
  SweetTalk::Tool::Words.load(root)
ensure
  FileUtils.rm_rf(root) if root
end

private def problems(source : String) : Array(String)
  SweetTalk::Tool::WordDrift.new(vocabulary(source)).source
end

# Runs the tool program's command *arguments* in an application whose lib/ holds this
# checkout's shard, for an agent or a person, and yields its status, output and errors.
private def tool(arguments : Array(String), agent : Bool = true, installed : Bool = true, &)
  root = File.tempname("words-application")
  Dir.mkdir_p(File.join(root, "lib"))
  File.symlink(SHARD, File.join(root, SweetTalk::Tool::SHARD)) if installed
  output, errors = IO::Memory.new, IO::Memory.new
  status = SweetTalk::Tool.run(arguments, output, errors, root, agent)
  yield status, output.to_s, errors.to_s
ensure
  FileUtils.rm_rf(root) if root
end

describe SweetTalk::Tool::WordDoc do
  it "reads the tags of a block and ignores the prose before it" do
    section = SweetTalk::Tool::WordDoc.new(<<-DOC).sections.first
      Prose.

      @word noun | A thing,
        said over two lines.
      @usage thing NAME
      @option size | an integer | - | How many.
        Zero is allowed.
      @option means positional | text | none | What it is.
      @internal border
      @guide c-sweettalk-values
      @example requires caramel/tenancy
        context A do

          thing B
        end
      DOC
    section.kind.should eq("noun")
    section.summary.should eq("A thing, said over two lines.")
    section.options.map(&.name).should eq(["size", "means"])
    section.options.first.does.should eq("How many. Zero is allowed.")
    section.options.first.default.should be_nil
    section.options.last.default.should eq("none")
    section.options.last.positional.should be_true
    section.internal.should eq(["border"])
    section.requires.should eq(["caramel/tenancy"])
    section.example.should eq("context A do\n\n  thing B\nend")
    section.problems.should be_empty
  end

  it "reads an explicit name before the kind as a word the macro's body reads" do
    sections = SweetTalk::Tool::WordDoc.new("@word noun | One.\n@word b rule | Two.").sections
    sections.map(&.name).should eq([nil, "b"])
    sections.map(&.kind).should eq(["noun", "rule"])
  end

  it "names a line that is no tag, a malformed option and a repeated tag" do
    section = SweetTalk::Tool::WordDoc.new(<<-DOC).sections.first
      @word noun | A thing.
      @usage a
      @usage b
      @option size | only three cells | -
      a stray line
      @bogus
      DOC
    section.problems.size.should eq(4)
    section.problems.join("\n").should contain("@usage is given twice")
    section.problems.join("\n").should contain("@option reads")
    section.problems.join("\n").should contain("indent a continuation by two spaces")
    section.problems.join("\n").should contain("\"@bogus\" is no tag")
  end

  it "finds no block in a comment without @word" do
    SweetTalk::Tool::WordDoc.new("Only prose.\n@usage x").blocks?.should be_false
  end
end

describe SweetTalk::Tool::Words do
  it "reads a word, its parameters and its block, and sets its refusal apart" do
    words = vocabulary
    words.words.should eq(["thing"])
    words.stubs.map(&.scope).should eq(["SweetTalk::Model"])
    form = words.forms_of("thing").first
    form.where.should eq("in a context")
    form.keywords.map(&.name).should eq(["size", "means"])
    form.options.map(&.name).should eq(["size", "means"])
    form.location.should end_with("thing.cr:16")
  end

  it "names the nearest words of a misspelling, and none for a stranger" do
    words = vocabulary
    words.nearest("thnig").should eq(["thing"])
    words.nearest("completely").should be_empty
  end

  it "prints a listing, one word, and JSON" do
    words = vocabulary
    listing = words.to_text
    listing.should contain("noun: declares a thing the glossary lists\n  thing  Declares a thing")
    one = words.to_text("thing")
    one.should contain("In a context: Declares a thing the glossary lists.\n")
    one.should contain("  thing NAME[, size: N], means: TEXT\n")
    one.should contain("    size:  an integer\n        How many jars it holds. Zero is allowed.\n")
    one.should contain("Guide: https://caramelize.dev/docs/#{Caramel::VERSION}/sweettalk/")
    one.should contain("    context Pantry, means: \"what we keep\" do\n")
    document = JSON.parse(JSON.build { |json| words.word_json(json, "thing") })
    document["forms"][0]["options"][0]["name"].should eq("size")
    document["forms"][0]["requires"].as_a.should be_empty
  end
end

describe SweetTalk::Tool::WordDrift do
  it "finds nothing wrong with a word whose block matches its macro" do
    problems(THING).should be_empty
  end

  it "names a parameter without an option and an option without a parameter" do
    without_means = THING.sub("# @option means | text | - | What the thing is.\n", "")
    bogus = "    # @option extent | an integer | - | Bogus.\n"
    broken = without_means.sub("    # @option size", "#{bogus}    # @option size")
    text = problems(broken).join("\n")
    text.should contain("parameter means has no @option or @internal line")
    text.should contain("@option extent names no parameter with a default")
    text.should contain("@usage writes means:, which is no @option")
  end

  it "names a macro that has no block and is no refusal" do
    untagged = THING.lines.reject(&.includes?("# @")).join('\n')
    text = problems(untagged)
    text.join("\n").should contain("macro thing (src/sweettalk/thing.cr:")
    text.join("\n").should contain(") has no @word block")
  end

  it "holds usage, kind, example and guide to the word" do
    problems(THING.sub("thing NAME[, size: N], means: TEXT", "thing NAME, means: TEXT"))
      .join("\n").should contain("@usage does not write size:, an @option")
    problems(THING.sub("@word noun", "@word creature"))
      .join("\n").should contain("@word says kind \"creature\"")
    problems(THING.sub("thing Jar,", "jar Jar,"))
      .join("\n").should contain("its @example never uses thing")
    problems(THING.sub("size: 3,", "size: 3, bogus: 1,"))
      .join("\n").should contain("its @example passes bogus:, which is no @option")
    problems(THING.sub("    # @guide c-sweettalk-values\n", ""))
      .join("\n").should contain("has no @guide section")
    problems(THING.sub("Declares a thing the glossary lists.", "x" * 101))
      .join("\n").should contain("its summary is 101 characters")
  end

  it "names a @guide that is no section of the guide" do
    drift = SweetTalk::Tool::WordDrift.new(vocabulary)
    drift.sections("## Values {#c-sweettalk-values}", "the guide").should be_empty
    drift.sections("## Other {#c-sweettalk-other}", "the guide").first
      .should contain("@guide c-sweettalk-values is no section of the guide")
  end

  it "reads the guide and the skill for options and words that do not exist" do
    drift = SweetTalk::Tool::WordDrift.new(vocabulary)
    ok = "Use `thing Jar, size: 3, means: \"x\"` and `size:` and `means:`; thing is a word."
    drift.prose(ok, "guide.md", guide: true).should be_empty
    text = drift.prose("`thing Jar, sise: 3`, `colour:` and thing, size: and means:",
      "guide.md", guide: true).join("\n")
    text.should contain("guide.md:1: thing is written with sise:, which no form of thing takes")
    text.should contain("guide.md:1: `colour:` is no option of any SweetTalk word")
    drift.prose("size: and means: and thing in prose", "guide.md", guide: true).join("\n")
      .should contain("guide.md never names the word thing in code")
    drift.prose("thing, means:", "guide.md", guide: true).join("\n")
      .should contain("guide.md never names the option size:")
  end

  it "builds one program from the examples, a module for each" do
    program = SweetTalk::Tool::WordDrift.new(vocabulary).programs("../..")[[] of String]
    requires = "require \"../../src/caramel\"\nrequire \"../../sweettalk/src/sweettalk\"\n\n"
    program.should start_with(requires)
    program.should contain("module Example1\n  include SweetTalk\n\n  context Pantry")
    program.should end_with("\nSweetTalk.boot\n")
  end

  it "requires the framework's decimal before a module that needs it" do
    money = THING.sub("# @example\n", "# @example requires sweettalk/money\n")
    program = SweetTalk::Tool::WordDrift.new(vocabulary(money)).programs("..")[["sweettalk/money"]]
    program.should start_with(<<-CRYSTAL)
      require "../src/caramel"
      require "../src/sugar_orm/decimal"
      require "../sweettalk/src/sweettalk"
      require "../sweettalk/src/sweettalk/money"

      CRYSTAL
  end
end

describe "frappe sweettalk:words" do
  it "lists every word of the shard the application installed" do
    tool(["words"]) do |status, output, errors|
      status.should eq(0)
      output.should contain("SweetTalk words in Caramel #{Caramel::VERSION}: ")
      output.should contain("noun: declares a thing the glossary lists")
      errors.should eq("")
    end
  end

  it "prints a word's usage, options and example, and the same as JSON" do
    tool(["words", "value"]) do |status, output, _|
      status.should eq(0)
      output.should contain("  value NAME, TYPE")
      output.should contain("    at_least:  ")
      output.should contain("    context ")
    end
    tool(["words", "value", "--json"]) do |status, output, _|
      status.should eq(0)
      document = JSON.parse(output)
      document["word"].should eq("value")
      document["forms"][0]["source"].as_s.should start_with("lib/sweettalk/src/sweettalk/")
    end
    tool(["words", "--json"]) do |status, output, _|
      status.should eq(0)
      document = JSON.parse(output)
      document["version"].should eq(Caramel::VERSION)
      document["words"].as_a.map(&.["word"].as_s).should contain("whenever")
    end
  end

  it "names the nearest words of an unknown word and exits 1" do
    tool(["words", "valeu"]) do |status, output, errors|
      status.should eq(1)
      output.should eq("")
      errors.should eq(<<-MRDP)
        ERR USAGE at frappe sweettalk:words
        MSG: unknown word valeu; nearest: value
        SYNTAX: frappe sweettalk:words [WORD] [--json]
        SUGGEST: value

        MRDP
    end
    tool(["words", "valeu"], agent: false) do |status, _, errors|
      status.should eq(1)
      errors.should eq(<<-TEXT)
        frappe sweettalk:words: unknown word valeu; nearest: value
        Usage: frappe sweettalk:words [WORD] [--json]
        Did you mean value?
        Run frappe sweettalk:words --help for details.

        TEXT
    end
  end

  it "answers where lib/ holds no shard with a message, not a trace" do
    tool(["words"], installed: false) do |status, _, errors|
      status.should eq(1)
      errors.should contain("MSG: SweetTalk's source is missing: ")
      errors.should contain("Run frappe setup to install it.")
    end
  end

  it "refuses a command the manifest does not declare" do
    tool(["glossary"]) do |status, _, errors|
      status.should eq(2)
      errors.should eq("ERR USAGE at frappe sweettalk:glossary\nMSG: unknown command\n")
    end
  end
end

describe "SweetTalk's macros" do
  it "state every word's block, and the block matches the macro" do
    words = SweetTalk::Tool::Words.load(SHARD, REPO)
    SweetTalk::Tool::WordDrift.new(words).source.should be_empty
    words.forms.first.file.should start_with("sweettalk/src/sweettalk/")
  end

  it "hold no word in the tool program's own files" do
    files = SweetTalk::Tool::Words.load(SHARD, REPO).forms.map(&.file).uniq!
    files.select(&.includes?("/tool")).should be_empty
  end

  it "give the skill no option a word lacks" do
    skill = File.read(File.join(REPO, SKILL))
    drift = SweetTalk::Tool::WordDrift.new(SweetTalk::Tool::Words.load(SHARD, REPO))
    drift.prose(skill, SKILL).should be_empty
  end
end
