require "spec"
require "file_utils"
require "./support/shard_project"
require "../../src/frappe/cli"

private BUILTIN = Caramel::Frappe::Commands.builtin
# The first word of each built-in command, in the table's order.
private ROOTS = Caramel::Frappe::Commands::TABLE.map(&.words.first).uniq!
# Where the shells find each script and a stand-in `frappe`, which records the words a
# script asks about in `asked` and answers with `answer`.
private HARNESS  = File.tempname("frappe-completion-")
private STAND_IN = <<-SH
  #!/bin/sh
  printf '%s\\n' "$@" > "$(dirname "$0")/asked"
  cat "$(dirname "$0")/answer"\n
  SH
# A manifest Frappé refuses: its one command has no brief.
private BRIEFLESS = ShardProject.manifest([ShardProject.entry("greet NAME", brief: nil)])

# The status, standard output and standard error of the hidden command for *typed*,
# run in the current directory.
private def hidden(typed : Array(String)) : {Int32, String, String}
  output, errors = IO::Memory.new, IO::Memory.new
  frappe = Caramel::Frappe::CLI.new("/missing-framework", output, errors)
  status = frappe.run(["__complete"] + typed)
  {status, output.to_s, errors.to_s}
end

# The same, run in *directory*.
private def answered(typed : Array(String), directory : String) : {Int32, String, String}
  Dir.cd(directory) { hidden(typed) }
end

# The words the hidden command offers for *typed* in *directory*.
private def candidates(typed : Array(String), directory : String) : Array(String)
  status, answer, errors = answered(typed, directory)
  {status, errors}.should eq({0, ""})
  answer.lines.map(&.split('\t').first)
end

# Yields a directory that is no project.
private def outside(&)
  directory = File.tempname("frappe-completion-outside-")
  Dir.mkdir(directory)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

# Yields a project that depends on the fixture shard, and its commands.
private def project(&)
  ShardProject.create({"demo" => ShardProject.fixture}) do |root|
    yield root, Caramel::Frappe::ShardCommands.load(root).table
  end
end

# What *shell* prints for *arguments* while the stand-in answers as Frappé does for
# *typed* among the commands of *table*.
private def shell(shell : String,
                  arguments : Array(String),
                  typed : Array(String),
                  table : Caramel::Frappe::Commands::Table,
                  chdir : String? = nil) : Array(String)
  File.write(File.join(HARNESS, "answer"), Caramel::Frappe::Completion.answer(table, typed))
  File.delete?(File.join(HARNESS, "asked"))
  output = IO::Memory.new
  path = {"PATH" => "#{HARNESS}:#{ENV["PATH"]}"}
  inherit = Process::Redirect::Inherit
  Process.run(shell, arguments, env: path, output: output, error: inherit, chdir: chdir)
  output.to_s.lines.reject(&.empty?)
end

# The words the script last asked the stand-in about, or nil when it did not ask.
private def asked : Array(String)?
  path = File.join(HARNESS, "asked")
  File.read(path).lines if File.exists?(path)
end

private def quoted(words : Array(String)) : String
  words.join(' ') { |word| "'#{word}'" }
end

# What bash offers for *typed*, the words after `frappe`, the last under the cursor.
# bash 4 and later hand the function each word broken at `:` and `=`, which *broken*
# imitates; bash 3 hands it whole. *setup* runs before the function.
private def bash(typed : Array(String),
                 table : Caramel::Frappe::Commands::Table = BUILTIN,
                 broken : Bool = true,
                 setup : String = "",
                 chdir : String? = nil) : Array(String)
  pieces = typed.flat_map do |word|
    broken && !word.empty? ? word.scan(/[:=]+|[^:=]+/).map(&.[0]) : [word]
  end
  program = <<-BASH
    source #{HARNESS}/frappe.bash
    #{setup}
    COMP_WORDS=(frappe #{quoted(pieces)}); COMP_CWORD=#{pieces.size}
    _frappe
    printf '%s\\n' "${COMPREPLY[@]}"
    BASH
  shell("bash", ["--norc", "--noprofile", "-c", program], typed, table, chdir)
end

# What the zsh function hands the completion system for *typed*: each described word
# as _describe reads it, each word that takes no space after it, or FILES.
private def zsh(typed : Array(String),
                table : Caramel::Frappe::Commands::Table = BUILTIN) : Array(String)
  program = <<-ZSH
    compdef() { : }
    _describe() { print -rl -- "${(@P)4}" }
    compadd() { print -rl -- "${@[4,-1]}" }
    _files() { print -r -- FILES }
    source #{HARNESS}/frappe.zsh
    words=(frappe #{quoted(typed)}); CURRENT=#{typed.size + 1}
    _frappe
    ZSH
  shell("zsh", ["-f", "-c", program], typed, table)
end

# What fish offers for *typed*, each word with a tab before its description.
private def fish(typed : Array(String),
                 table : Caramel::Frappe::Commands::Table = BUILTIN,
                 chdir : String? = nil) : Array(String)
  program = "source #{HARNESS}/frappe.fish; complete -C 'frappe #{typed.join(' ')}'"
  shell("fish", ["--no-config", "-c", program], typed, table, chdir)
end

describe Caramel::Frappe::Completion do
  Dir.mkdir(HARNESS)
  %w[bash zsh fish].each do |name|
    File.write(File.join(HARNESS, "frappe.#{name}"), Caramel::Frappe::Completion.script(name))
  end
  File.write(File.join(HARNESS, "frappe"), STAND_IN)
  File.chmod(File.join(HARNESS, "frappe"), 0o755)
  Spec.after_suite { FileUtils.rm_rf(HARNESS) }

  describe "the hidden command" do
    it "offers commands, subcommands, options and choices, each command with its line" do
      outside do |directory|
        candidates([""], directory).should eq(ROOTS)
        candidates(["d"], directory).should eq(ROOTS)
        candidates(["db", "br"], directory).should eq(%w[dump restore diff branch diagnose])
        candidates(["db", "branch", ""], directory).should eq(%w[create list delete])
        candidates(["help", "db", ""], directory).should eq(candidates(["db", ""], directory))
        candidates(["make", "resource", "Book", "--pl"], directory).should contain("--plural=")
        candidates(["logs", ""], directory).should eq(%w[app compiler access --follow])
        candidates(["db", "restore", ""], directory).should be_empty
        _, answer, _ = answered(["db", "branch", ""], directory)
        answer.lines.first.should eq("create\t#{BUILTIN.brief(%w[db branch create])}")
        _, answer, _ = answered(["logs", ""], directory)
        answer.should eq("app\ncompiler\naccess\n--follow\n")
      end
    end

    it "offers a project's contributed commands after the built-ins, and their options" do
      project do |root, _|
        candidates(["de"], root).should eq(ROOTS + ["demo:greet", "demo:notes"])
        candidates(["demo:notes", ""], root).should eq(%w[list add])
        candidates(["demo:greet", "Ada", "--"], root).should eq(["--loud"])
        candidates(["help", "demo:notes", ""], root).should eq(%w[list add])
        _, answer, _ = answered(["demo:"], root)
        answer.lines.last(2).should eq([
          "demo:greet\tGreet someone by name", "demo:notes\tList or add notes",
        ])
      end
    end

    it "offers exactly the built-ins outside a project" do
      outside do |directory|
        Dir.mkdir_p(File.join(directory, "lib/demo"))
        File.write(File.join(directory, "lib/demo/frappe.yml"), ShardProject.fixture)
        candidates(["demo:"], directory).should eq(ROOTS)
        candidates(["demo:greet", ""], directory).should eq(ROOTS)
      end
    end

    it "offers the built-ins and says nothing of a manifest that Frappé refuses" do
      ShardProject.create({"demo" => BRIEFLESS}) do |root|
        status, answer, errors = answered([""], root)
        {status, errors}.should eq({0, ""})
        answer.lines.map(&.split('\t').first).should eq(ROOTS)
      end
    end

    it "offers nothing, says nothing and exits 0 when it cannot answer" do
      directory = File.tempname("frappe-completion-gone-")
      Dir.mkdir(directory)
      gone = Dir.cd(directory) do
        Dir.delete(directory)
        hidden([""])
      end
      gone.should eq({0, "", ""})
    end

    it "is absent from help, the agent manifest and its own candidates" do
      project do |root, _|
        [["help"], ["agent-manifest"], ["help", "completion"]].each do |arguments|
          output, errors = IO::Memory.new, IO::Memory.new
          frappe = Caramel::Frappe::CLI.new("/missing-framework", output, errors)
          Dir.cd(root) { frappe.run(arguments) }.should eq(0)
          (output.to_s + errors.to_s).should_not contain("__complete")
        end
        candidates([""], root).should_not contain("__complete")
        candidates(["__complete", ""], root).should_not contain("__complete")
      end
    end
  end

  describe "the bash script" do
    it "asks Frappé about the words typed so far and offers those that match" do
      bash(["db", "br"]).should eq(["branch"])
      asked.should eq(["__complete", "db", "br"])
      bash([""]).should eq(ROOTS)
      asked.should eq(["__complete", ""])
      bash(["db", "branch", ""]).should eq(%w[create list delete])
      bash(["help", "db", ""]).should eq(%w[dump restore diff branch diagnose])
      bash(["logs", ""]).should eq(%w[app compiler access --follow])
      bash(["make", "resource", "Book", "--pl"]).should eq(["--plural="])
    end

    it "completes nothing inside --name=VALUE, and does not ask" do
      bash(["make", "resource", "Book", "--plural="]).should be_empty
      asked.should be_nil
      bash(["make", "resource", "Book", "--plural=boo"]).should be_empty
      bash(["make", "resource", "Book", "--plural=boo"], broken: false).should be_empty
    end

    it "falls back to file names where a command takes a file" do
      outside do |directory|
        File.write(File.join(directory, "backup.dump"), "")
        bash(%w[db restore ba], chdir: directory).should eq(["backup.dump"])
      end
    end

    it "completes shard:command as one word, though bash breaks words at the colon" do
      project do |_, table|
        matching = ROOTS.select(&.starts_with?("de"))
        bash(["de"], table).should eq(matching + ["demo:greet", "demo:notes"])
        # bash replaces what follows the colon, so that is what the script offers.
        bash(["demo:"], table).should eq(%w[greet notes])
        asked.should eq(["__complete", "demo:"])
        bash(["demo:gr"], table).should eq(["greet"])
        asked.should eq(["__complete", "demo:gr"])
        bash(["demo:gr"], table, broken: false).should eq(["greet"])
        bash(["demo:notes", ""], table).should eq(%w[list add])
        asked.should eq(["__complete", "demo:notes", ""])
        bash(["help", "demo:notes", "a"], table).should eq(["add"])
        bash(["demo:greet", "Ada", "--"], table).should eq(["--loud"])
      end
    end

    it "offers the whole word where the colon breaks no word" do
      project do |_, table|
        unbroken = "COMP_WORDBREAKS=${COMP_WORDBREAKS//:/}"
        offered = bash(["demo:gr"], table, broken: false, setup: unbroken)
        offered.should eq(["demo:greet"])
      end
    end
  end

  describe "the zsh script" do
    it "asks Frappé about the words typed so far and describes each command" do
      described = %w[create list delete].map do |word|
        "#{word}:#{BUILTIN.brief(["db", "branch", word])}"
      end
      zsh(["db", "branch", ""]).should eq(described)
      asked.should eq(["__complete", "db", "branch", ""])
      zsh(["logs", ""]).should eq(%w[app compiler access --follow])
      zsh(["help", "db", "br"]).should contain("branch:#{BUILTIN.brief(%w[db branch])}")
      asked.should eq(["__complete", "help", "db", "br"])
    end

    it "adds no space after an option written --name=VALUE" do
      offered = zsh(["make", "resource", "Book", "--pl"])
      offered.should contain("--plural=")
      offered.should_not contain("FILES")
    end

    it "falls back to file names where Frappé offers nothing" do
      zsh(["new", ""]).should eq(["FILES"])
    end

    it "escapes the colon of shard:command, which separates a word from its description" do
      project do |_, table|
        offered = zsh(["de"], table)
        offered.last(2).should eq([
          "demo\\:greet:Greet someone by name", "demo\\:notes:List or add notes",
        ])
        offered.first.should eq("#{ROOTS.first}:#{BUILTIN.brief([ROOTS.first])}")
        zsh(["demo:"], table).should eq(offered)
        asked.should eq(["__complete", "demo:"])
        zsh(["demo:notes", ""], table).should eq(["list:List the notes", "add:Add a note"])
        zsh(["demo:greet", "Ada", "--"], table).should eq(["--loud"])
      end
    end
  end

  describe "the fish script" do
    # fish is no part of macOS or of the toolchain: these run where it is installed.
    if Process.find_executable("fish")
      it "asks Frappé about the words typed so far and describes each command" do
        outside do |directory|
          fish(["db", "br"], chdir: directory).should eq([
            "branch\t#{BUILTIN.brief(%w[db branch])}",
          ])
          asked.should eq(["__complete", "db", "br"])
          fish(["db", "branch", ""], chdir: directory).map(&.split('\t').first)
            .should eq(%w[create list delete])
          asked.should eq(["__complete", "db", "branch", ""])
          fish(["logs", ""], chdir: directory).should eq(%w[app compiler access --follow])
          fish(["logs", "--"], chdir: directory).should eq(["--follow"])
          fish(["make", "resource", "Book", "--pl"], chdir: directory).should eq(["--plural="])
        end
      end

      it "falls back to file names where a command takes a file" do
        outside do |directory|
          File.write(File.join(directory, "backup.dump"), "")
          fish(%w[db restore ba], chdir: directory).should eq(["backup.dump"])
          fish(%w[db branch ba], chdir: directory).should be_empty
        end
      end

      it "completes shard:command as one word" do
        project do |_, table|
          outside do |directory|
            greet = "demo:greet\tGreet someone by name"
            notes = "demo:notes\tList or add notes"
            fish(["demo:"], table, chdir: directory).should eq([greet, notes])
            asked.should eq(["__complete", "demo:"])
            fish(["demo:gr"], table, chdir: directory).should eq([greet])
            fish(["de"], table, chdir: directory).last(2).should eq([greet, notes])
            fish(["demo:notes", ""], table, chdir: directory).should eq([
              "list\tList the notes", "add\tAdd a note",
            ])
            fish(["demo:greet", "Ada", "--"], table, chdir: directory).should eq(["--loud"])
          end
        end
      end
    else
      pending "completes commands, file names and shard:command as one word (fish not found)"
    end
  end
end
