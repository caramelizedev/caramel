require "../caramel/version"
require "./commands"
require "./terminal"

module Caramel::Frappe
  # What `frappe help`, `frappe help WORDS` and `WORDS --help` print, all read from
  # a command table: uppercase headings (bold on a colour terminal), content
  # indented two spaces, sections separated by a blank line, lines of at most WIDTH.
  module Help
    WIDTH = 80
    # frappe help's EXAMPLES; commands_spec parses each.
    EXAMPLES = ["new my-app", "make resource Book title:string author:string",
                "db branch create spike", "dev --branch spike"]

    # Every command grouped by task, then one group for each shard that contributes some.
    def self.overview(table : Commands::Table, color : Bool) : String
      width = table.groups.max_of { |group| group.names.max_of(&.size) } + 2
      String.build do |io|
        io << "Frappé creates, runs and checks Caramel applications.\n"
        io << '\n'
        heading(io, "USAGE", color)
        io << "  frappe COMMAND [ARGUMENTS]\n"
        table.groups.each do |group|
          io << '\n'
          heading(io, group.title, color)
          rows(io, group.names.map { |name| {name, table.brief([name])} }, width)
        end
        io << '\n'
        heading(io, "EXAMPLES", color)
        EXAMPLES.each { |example| io << "  $ frappe " << example << '\n' }
        io << '\n'
        heading(io, "LEARN MORE", color)
        io << "  Use frappe help COMMAND for a command's usage and examples.\n"
        io << "  Run frappe doctor when something does not work.\n"
        io << "  Guides: " << Caramel::WEBSITE << "/docs/" << Caramel::VERSION << "/\n"
        io << "  Report a problem: " << Caramel::REPOSITORY << "/issues\n"
        io << "  Coding agents: frappe agent-manifest prints every command in full.\n"
      end
    end

    # One command: its description, usage and examples, then its subcommands
    # when it is also the root of a family (`frappe lsp`).
    def self.command(table : Commands::Table, command : Commands::Command, color : Bool) : String
      String.build do |io|
        text = command.summary
        text += " Works outside an application." unless command.project?
        Terminal.wrap(text, WIDTH).each { |line| io << line << '\n' }
        io << '\n'
        heading(io, "USAGE", color)
        usage_lines(command).each { |line| io << line << '\n' }
        unless command.examples.empty?
          io << '\n'
          heading(io, "EXAMPLES", color)
          command.examples.each { |example| io << "  $ frappe " << example << '\n' }
        end
        subcommands = table.matching(command.words).reject(&.same?(command))
        unless subcommands.empty?
          io << '\n'
          heading(io, "COMMANDS", color)
          width = subcommands.max_of(&.name.size) + 2
          rows(io, subcommands.map { |sub| {sub.name, sub.brief} }, width)
        end
        io << '\n'
        heading(io, "LEARN MORE", color)
        io << "  " << source(command) << '\n'
      end
    end

    # A run of command words that begins longer commands: its subcommands.
    def self.family(table : Commands::Table, words : Array(String), color : Bool) : String
      commands = table.matching(words)
      deeper = commands.find { |command| command.words.size > words.size }
      listing(table.families[words.join(' ')], commands, deeper, source(commands.first), color)
    end

    # The commands a shard contributes, for `frappe help SHARD`.
    def self.shard(table : Commands::Table, shard : String, color : Bool) : String
      commands = table.contributed(shard)
      line = "The commands the #{shard} shard contributes"
      listing(line, commands, commands.first?, nil, color)
    end

    # *line*, then *commands* with their briefs, the command whose help shows a usage
    # and examples, and where to read more.
    private def self.listing(line : String,
                             commands : Array(Commands::Command),
                             example : Commands::Command?,
                             more : String?,
                             color : Bool) : String
      width = commands.max_of(&.name.size) + 2
      String.build do |io|
        io << line << ".\n"
        io << '\n'
        heading(io, "COMMANDS", color)
        rows(io, commands.map { |command| {command.name, command.brief} }, width)
        io << '\n'
        heading(io, "LEARN MORE", color)
        if example
          io << "  Use frappe help " << example.name << " for a command's usage and examples.\n"
        end
        io << "  " << more << '\n' if more
      end
    end

    private def self.heading(io : IO, title : String, color : Bool) : Nil
      io << Terminal.bold(title, color) << '\n'
    end

    private def self.rows(io : IO, rows : Array(Tuple(String, String)), width : Int32) : Nil
      rows.each { |name, brief| io << "  " << name.ljust(width) << brief << '\n' }
    end

    # Where to read more about *command*: the guides' commands page for one Frappé
    # defines, its shard's list for one a shard contributes.
    private def self.source(command : Commands::Command) : String
      shard = command.shard
      return "#{Caramel::WEBSITE}/docs/#{Caramel::VERSION}/commands/" unless shard
      "Use frappe help #{shard} for the #{shard} shard's commands."
    end

    # `frappe` and the syntax's tokens, continued on a deeper-indented line
    # when the next token would pass WIDTH. A token is never split.
    private def self.usage_lines(command : Commands::Command) : Array(String)
      lines = ["  frappe"]
      Commands.tokens(command.syntax).each do |token|
        if lines.last.size + 1 + token.size <= WIDTH
          lines[-1] = "#{lines.last} #{token}"
        else
          lines << "      #{token}"
        end
      end
      lines
    end
  end
end
