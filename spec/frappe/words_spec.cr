require "spec"
require "file_utils"
require "../../src/frappe/cli"
require "../../src/frappe/word_drift"

private REPO = File.expand_path("../..", __DIR__)

# A SweetTalk source tree of one word, `thing`, and a refusal for it, as the macros write them.
private THING = <<-CRYSTAL
  module SweetTalk
    module BoundedContext
      # Prose for contributors, which `frappe words` ignores.
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

# Loads the words of a source tree holding *source*.
private def vocabulary(source : String = THING) : Caramel::Frappe::Words
  root = File.tempname("words-spec")
  directory = File.join(root, Caramel::Frappe::Words::SOURCE)
  FileUtils.mkdir_p(directory)
  File.write(File.join(directory, "thing.cr"), source)
  Caramel::Frappe::Words.load(root)
ensure
  FileUtils.rm_rf(root) if root
end

private def problems(source : String) : Array(String)
  Caramel::Frappe::WordDrift.new(vocabulary(source)).source
end

private def cli : {Caramel::Frappe::CLI, IO::Memory, IO::Memory}
  output, errors = IO::Memory.new, IO::Memory.new
  {Caramel::Frappe::CLI.new(REPO, output, errors), output, errors}
end

describe Caramel::Frappe::WordDoc do
  it "reads the tags of a block and ignores the prose before it" do
    section = Caramel::Frappe::WordDoc.new(<<-DOC).sections.first
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
    sections = Caramel::Frappe::WordDoc.new("@word noun | One.\n@word b rule | Two.").sections
    sections.map(&.name).should eq([nil, "b"])
    sections.map(&.kind).should eq(["noun", "rule"])
  end

  it "names a line that is no tag, a malformed option and a repeated tag" do
    section = Caramel::Frappe::WordDoc.new(<<-DOC).sections.first
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
    Caramel::Frappe::WordDoc.new("Only prose.\n@usage x").blocks?.should be_false
  end
end

describe Caramel::Frappe::Words do
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

describe Caramel::Frappe::WordDrift do
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
    text.join("\n").should contain("macro thing (src/caramel/sweet_talk/thing.cr:")
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
    drift = Caramel::Frappe::WordDrift.new(vocabulary)
    drift.sections("## Values {#c-sweettalk-values}", "the guide").should be_empty
    drift.sections("## Other {#c-sweettalk-other}", "the guide").first
      .should contain("@guide c-sweettalk-values is no section of the guide")
  end

  it "reads the guide and the skill for options and words that do not exist" do
    drift = Caramel::Frappe::WordDrift.new(vocabulary)
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
    program = Caramel::Frappe::WordDrift.new(vocabulary).programs("../..")[[] of String]
    program.should start_with("require \"../../src/caramel/sweet_talk\"\n")
    program.should contain("module Example1\n  include SweetTalk\n\n  context Pantry")
    program.should end_with("\nSweetTalk.boot\n")
  end
end

describe "frappe words" do
  it "lists every word of this release without an application" do
    frappe, output, errors = cli
    frappe.run(["words"]).should eq(0)
    output.to_s.should contain("SweetTalk words in Caramel #{Caramel::VERSION}: ")
    output.to_s.should contain("noun: declares a thing the glossary lists")
    errors.to_s.should eq("")
  end

  it "prints a word's usage, options and example, and the same as JSON" do
    frappe, output, _ = cli
    frappe.run(["words", "value"]).should eq(0)
    output.to_s.should contain("  value NAME, TYPE")
    output.to_s.should contain("    at_least:  ")
    output.to_s.should contain("    context ")
    output.clear
    frappe.run(["words", "value", "--json"]).should eq(0)
    JSON.parse(output.to_s)["word"].should eq("value")
    output.clear
    frappe.run(["words", "--json"]).should eq(0)
    document = JSON.parse(output.to_s)
    document["version"].should eq(Caramel::VERSION)
    document["words"].as_a.map(&.["word"].as_s).should contain("whenever")
  end

  it "names the nearest words of an unknown word and exits 1" do
    frappe, _, errors = cli
    frappe.run(["words", "valeu"]).should eq(1)
    errors.to_s.should contain("MSG: unknown word valeu; nearest: value")
    errors.to_s.should contain("SUGGEST: value")
  end

  it "answers beside an unreadable source with a message, not a trace" do
    output, errors = IO::Memory.new, IO::Memory.new
    Caramel::Frappe::CLI.new("/missing-framework", output, errors).run(["words"]).should eq(1)
    errors.to_s.should contain("This Frappé has no SweetTalk source")
  end
end

describe "SweetTalk's macros" do
  it "state every word's block, and the block matches the macro" do
    Caramel::Frappe::WordDrift.new(Caramel::Frappe::Words.load(REPO)).source.should be_empty
  end

  it "give the skill no option a word lacks" do
    skill = File.read(File.join(REPO, "templates/skills/sweettalk/SKILL.md"))
    drift = Caramel::Frappe::WordDrift.new(Caramel::Frappe::Words.load(REPO))
    drift.prose(skill, "templates/skills/sweettalk/SKILL.md").should be_empty
  end
end
