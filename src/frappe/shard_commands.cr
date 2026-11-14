require "yaml"
require "./commands"
require "./project"

module Caramel::Frappe
  # The commands a project's shards contribute (ADR 0013). A shard declares them in
  # `frappe.yml` at its root. Frappé reads the manifest of each shard that the project's
  # shard.lock locks and lib/ holds, names each command `shard:name`, and adds them
  # to the built-in table, one shard after another in name order. A manifest that breaks
  # a rule contributes nothing: its shard's commands are absent, and a Problem says why.
  #
  # A manifest names its format and lists its commands, each written without the shard's
  # name in the syntax grammar of Commands, and the line for each run of words that
  # begins longer commands:
  #
  # ```yaml
  # format: 1
  # commands:
  #   - syntax: notes add TEXT [--pinned]
  #     brief: Add a note
  #     description: Add the note TEXT; --pinned keeps it first.
  #     examples:
  #       - notes add "Call the roaster" --pinned
  #     run: application
  # families:
  #   notes: List or add notes
  # ```
  module ShardCommands
    FILE = "frappe.yml"
    # The manifest format this Frappé reads.
    FORMAT = 1
    # How a contributed command runs: as a command of the built application.
    RUNS  = %w[application]
    LIMIT = 1_048_576

    # Why a shard's commands are absent: its manifest, the rule it breaks and the remedy.
    record Problem, shard : String, file : String, rule : String, remedy : String do
      def message : String
        "#{file}: #{rule}. Frappé did not load the #{shard} shard's commands.\n#{remedy}"
      end
    end

    # A project's commands, and the manifests that contribute none.
    record Loaded, table : Commands::Table, problems : Array(Problem)

    # A rule a manifest breaks, and its remedy.
    private class Refusal < Exception
      getter remedy : String

      def initialize(rule : String, @remedy : String)
        super(rule)
      end
    end

    # One command as a manifest writes it.
    private struct Entry
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter syntax : String?
      getter brief : String?
      getter description : String?
      getter examples : Array(String) = [] of String
      getter run : String?
    end

    private struct Manifest
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter format : Int64
      getter commands : Array(Entry) = [] of Entry
      getter families : Hash(String, String) = {} of String => String
    end

    # The commands of the project at *root*: *builtin*, then what each of its shards
    # contributes. Outside a project, which pins no Caramel release, they are *builtin*.
    def self.load(root : String, builtin : Commands::Table = Commands.builtin) : Loaded
      table = builtin
      problems = [] of Problem
      shards(root).each do |shard|
        table += contribution(shard, File.join(root, file(shard)))
      rescue ex : Refusal
        problems << Problem.new(shard, file(shard), ex.message.to_s, ex.remedy)
      end
      Loaded.new(table, problems)
    end

    # Where *shard*'s manifest is, from the project's root.
    def self.file(shard : String) : String
      File.join("lib", shard, FILE)
    end

    # The shards a project locks and holds under lib/ with a manifest, in name order. A
    # name that cannot prefix a command is no shard's.
    private def self.shards(root : String) : Array(String)
      locked = Project.locked(root)
      return [] of String unless locked.has_key?("caramel")
      names = locked.keys.select { |name| "#{name}:x".matches?(Commands::NAMESPACED_WORD) }
      names.select! { |name| File.file?(File.join(root, file(name))) }
      names.sort!
    end

    # What *shard*'s manifest at *path* declares, as a table of its own.
    private def self.contribution(shard : String, path : String) : Commands::Table
      manifest = read(path)
      if manifest.commands.empty?
        refuse("the manifest declares no command",
          "List the shard's commands under commands, or remove the file.")
      end
      commands = manifest.commands.map { |entry| command(shard, entry) }
      once(shard, commands)
      lines = families(shard, commands, manifest.families)
      group = Commands::Group.new(shard.upcase, commands.map(&.words.first).uniq!)
      table = Commands::Table.new(commands, lines, [group])
      exemplified(shard, table)
      table
    end

    # The manifest at *path*, once its format is one this Frappé reads.
    private def self.read(path : String) : Manifest
      if File.size(path) > LIMIT
        refuse("the manifest is larger than 1 MiB", "Keep only the shard's commands in it.")
      end
      text = File.read(path)
      format = YAML.parse(text).as_h?.try(&.[YAML::Any.new("format")]?).try(&.as_i64?)
      unless format
        refuse("the manifest names no format", "Start it with format: #{FORMAT}.")
      end
      readable(format)
      Manifest.from_yaml(text)
    rescue ex : YAML::ParseException
      refuse("the manifest is malformed: #{ex.message.to_s.lines.first?}",
        "Write format, commands and families as the commands page of the guides shows.")
    rescue File::Error
      refuse("the manifest cannot be read", "Make it a file that you can read.")
    end

    # Refuses a format other than the one this Frappé reads.
    private def self.readable(format : Int64) : Nil
      return if format == FORMAT
      rule = "the manifest is format #{format}, and this Frappé reads format #{FORMAT}"
      if format > FORMAT
        refuse(rule, "Run the Caramel release the shard is written for, " \
                     "or install a version of the shard that this release reads.")
      end
      refuse(rule, "Write format: #{FORMAT}.")
    end

    # The command *entry* declares, under *shard*'s name.
    private def self.command(shard : String, entry : Entry) : Commands::Command
      syntax = entry.syntax.try(&.strip) || ""
      if syntax.empty?
        refuse("a command has no syntax",
          "Give each command a syntax, such as greet NAME [--loud].")
      end
      label = "the command #{syntax.inspect}"
      line(syntax, "syntax", label)
      brief = present(entry.brief, "brief", label)
      description = present(entry.description, "description", label)
      require_run(entry.run, label)
      examples = entry.examples.map { |example| "#{shard}:#{line(example, "example", label)}" }
      begin
        Commands::Command.new("#{shard}:#{syntax}", description, brief: brief, examples: examples)
      rescue ArgumentError
        refuse("#{label} does not start with a command word",
          "Start the syntax with a lowercase word, such as greet; Frappé adds #{shard}: itself.")
      end
    end

    # *value* stripped, refused when it is missing or takes more than one line.
    private def self.present(value : String?, field : String, label : String) : String
      text = value.try(&.strip) || ""
      if text.empty?
        refuse("#{label} has no #{field}", "Add #{field}: with one line of text to the command.")
      end
      line(text, field, label)
    end

    # *text* stripped, refused when it takes more than one line.
    private def self.line(text : String, field : String, label : String) : String
      text = text.strip
      return text unless text.includes?('\n')
      refuse("the #{field} of #{label} takes more than one line", "Write it on one line.")
    end

    # Refuses a command that does not say it runs in one of RUNS.
    private def self.require_run(run : String?, label : String) : Nil
      return if run && RUNS.includes?(run)
      rule = if run
               "#{label} runs as #{run.inspect}, and this Frappé runs a command as application"
             else
               "#{label} does not say how it runs"
             end
      refuse(rule, "Write run: application, and register the command in the shard's code.")
    end

    # Refuses two commands of one name.
    private def self.once(shard : String, commands : Array(Commands::Command)) : Nil
      names = commands.map(&.name)
      twice = names.find { |name| names.count(name) > 1 } || return
      refuse("the command #{plain(shard, twice).inspect} is declared twice",
        "Declare each command once.")
    end

    # The manifest's *lines* under *shard*'s name: one for each run of words that begins
    # a longer command, and no other.
    private def self.families(shard : String,
                              commands : Array(Commands::Command),
                              lines : Hash(String, String)) : Hash(String, String)
      runs = Commands.family_runs(commands)
      named = lines.to_h do |run, text|
        {"#{shard}:#{run.strip}", present(text, "line", "the family #{run.inspect}")}
      end
      (runs - named.keys).first?.try do |run|
        words = plain(shard, run)
        refuse("commands start with #{words.inspect}, and families has no line for it",
          "Add #{words}: under families, with the line help shows for those commands.")
      end
      (named.keys - runs).first?.try do |run|
        refuse("families has a line for #{plain(shard, run).inspect}, which starts no " \
               "longer command", "Remove the line, or declare the commands that start with it.")
      end
      named
    end

    # Refuses an example that does not parse as its own command.
    private def self.exemplified(shard : String, table : Commands::Table) : Nil
      table.commands.each do |command|
        command.examples.each do |example|
          reason = mismatch(table, command, example) || next
          label = "the command #{plain(shard, command.syntax).inspect}"
          refuse("the example #{plain(shard, example).inspect} does not parse as " \
                 "#{label}: #{reason}",
            "Write each example as the command's words and arguments, " \
            "without frappe and without #{shard}:.")
        end
      end
    end

    # Why *example* is not an invocation of *command*, or nil when it is one.
    private def self.mismatch(table : Commands::Table,
                              command : Commands::Command,
                              example : String) : String?
      parsed = table.parse(Process.parse_arguments_posix(example)).command
      "it is #{parsed.name}" unless parsed.same?(command)
    rescue ex : Commands::Usage
      ex.message
    end

    # *text* as the manifest writes it, without *shard*'s name.
    private def self.plain(shard : String, text : String) : String
      text.lchop("#{shard}:")
    end

    private def self.refuse(rule : String, remedy : String) : NoReturn
      raise Refusal.new(rule, remedy)
    end
  end
end
