require "../caramel/version"
require "./commands"
require "./terminal"

module Caramel::Frappe
  # What `frappe help`, `frappe help WORDS` and `WORDS --help` print, all read from
  # Commands::TABLE: uppercase headings (bold on a colour terminal), content
  # indented two spaces, sections separated by a blank line, lines of at most WIDTH.
  module Help
    WIDTH = 80
    # frappe help's EXAMPLES; commands_spec parses each.
    EXAMPLES = ["new my-app", "make resource Book title:string author:string",
                "db branch create spike", "dev --branch spike"]

    # Every command grouped by task.
    def self.overview(color : Bool) : String
      width = Commands::GROUPS.max_of { |group| group.names.max_of(&.size) } + 2
      String.build do |io|
        io << "Frappé creates, runs and checks Caramel applications.\n"
        io << '\n'
        heading(io, "USAGE", color)
        io << "  frappe COMMAND [ARGUMENTS]\n"
        Commands::GROUPS.each do |group|
          io << '\n'
          heading(io, group.title, color)
          rows(io, group.names.map { |name| {name, Commands.brief([name])} }, width)
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
    def self.command(command : Commands::Command, color : Bool) : String
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
        subcommands = Commands.matching(command.words).reject(&.same?(command))
        unless subcommands.empty?
          io << '\n'
          heading(io, "COMMANDS", color)
          width = subcommands.max_of(&.name.size) + 2
          rows(io, subcommands.map { |sub| {sub.name, sub.brief} }, width)
        end
        io << '\n'
        heading(io, "LEARN MORE", color)
        io << "  " << commands_page << '\n'
      end
    end

    # A run of command words that two or more commands share: its subcommands.
    def self.family(words : Array(String), color : Bool) : String
      commands = Commands.matching(words)
      width = commands.max_of(&.name.size) + 2
      String.build do |io|
        io << Commands::FAMILIES[words.join(' ')] << ".\n"
        io << '\n'
        heading(io, "COMMANDS", color)
        rows(io, commands.map { |command| {command.name, command.brief} }, width)
        io << '\n'
        heading(io, "LEARN MORE", color)
        if deeper = commands.find { |command| command.words.size > words.size }
          io << "  Use frappe help " << deeper.name << " for a command's usage and examples.\n"
        end
        io << "  " << commands_page << '\n'
      end
    end

    private def self.heading(io : IO, title : String, color : Bool) : Nil
      io << Terminal.bold(title, color) << '\n'
    end

    private def self.rows(io : IO, rows : Array(Tuple(String, String)), width : Int32) : Nil
      rows.each { |name, brief| io << "  " << name.ljust(width) << brief << '\n' }
    end

    private def self.commands_page : String
      "#{Caramel::WEBSITE}/docs/#{Caramel::VERSION}/commands/"
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
