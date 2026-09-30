require "./project"
require "../latte/postgres"

module Caramel::Frappe
  # Frappé's command line, stated once. Help, per-command usage, argument
  # validation, project dispatch and `frappe agent-manifest` all read TABLE.
  #
  # Syntax grammar: leading lowercase words name the command; `NAME` is a
  # positional, `a|b` a literal choice, `X...` one or more, `[...]` optional.
  # `--flag`, `--flag VALUE` and `--flag=VALUE` are options; `--a|--b`
  # excludes one another; a `=LOW..HIGH` value must be an integer in range.
  module Commands
    # A malformed invocation. `commands` are the intended commands, whose
    # syntax the error prints; `subject` names what was invoked.
    class Usage < Error
      getter subject : String
      getter commands : Array(Command)
      getter suggestion : String?

      def initialize(message : String,
                     @subject : String,
                     @commands : Array(Command) = [] of Command,
                     @suggestion : String? = nil)
        super(message)
      end

      def syntax : String?
        @commands.empty? ? nil : @commands.join(" | ") { |command| "frappe #{command.syntax}" }
      end
    end

    record Flag, names : Array(String), value : String?, equals : Bool, optional : Bool
    record Positional, name : String, choices : Array(String)?, optional : Bool, repeat : Bool

    class Command
      getter syntax : String
      getter description : String
      getter? project : Bool
      # The final repeated positional takes every remaining argument verbatim.
      getter? passthrough : Bool
      # A command kept for one release before its removal (ADR 0016): what
      # replaces it. Invoking it warns with this text.
      getter deprecated : String?
      getter words = [] of String
      getter flags = [] of Flag
      getter positionals = [] of Positional

      def initialize(@syntax : String,
                     @description : String,
                     *,
                     @project : Bool = true,
                     @passthrough : Bool = false,
                     @deprecated : String? = nil)
        Commands.tokens(@syntax).each do |token|
          optional = token.starts_with?('[')
          text = optional ? token[1...-1] : token
          if text.starts_with?("--")
            head, space, spaced = text.partition(' ')
            name, equals, assigned = head.partition('=')
            value = space.empty? ? (equals.empty? ? nil : assigned) : spaced
            @flags << Flag.new(name.split('|'), value, !equals.empty?, optional)
          elsif !optional && @flags.empty? && @positionals.empty? &&
                text.matches?(/\A[a-z][a-z-]*\z/)
            @words << text
          else
            name = text.rchop("...")
            @positionals << Positional.new(
              name: name,
              choices: name.matches?(/\A[a-z]/) ? name.split('|') : nil,
              optional: optional,
              repeat: text.ends_with?("..."))
          end
        end
      end

      def name : String
        @words.join(' ')
      end

      # The description help and the agent manifest print.
      def summary : String
        replacement = @deprecated || return @description
        "#{@description} Deprecated: #{replacement}"
      end
    end

    # A validated invocation: positional values by placeholder, repeated
    # positionals by placeholder, option values by option, and given options.
    record Invocation,
      command : Command,
      values : Hash(String, String),
      lists : Hash(String, Array(String)),
      flags : Set(String) do
      def [](key : String) : String
        values[key]
      end

      def []?(key : String) : String?
        values[key]?
      end

      def list(key : String) : Array(String)
        lists[key]? || [] of String
      end

      def flag?(key : String) : Bool
        flags.includes?(key)
      end
    end

    MODE = "[--agent|--human]"

    TABLE = [
      Command.new("help", "Print every command with its description.", project: false),
      Command.new("version", "Print the Frappé version.", project: false),
      Command.new("agent-manifest",
        "Print this strict command list and the MRDP diagnostic grammar " \
        "for coding agents.",
        project: false),
      Command.new("new NAME",
        "Create the application ./NAME, install its locked dependencies " \
        "and register it with Latte.",
        project: false),
      Command.new("setup",
        "Install locked dependencies and register this project with Latte, " \
        "preserving existing files."),
      Command.new("dev [--no-open] [--branch NAME]",
        "Build, serve and reload the app at its HTTPS origin; " \
        "--branch runs it against database branch NAME."),
      Command.new("check #{MODE}",
        "Run the Tier-1 type check (crystal build --no-codegen) " \
        "and report diagnostics; MRDP unless stdout is a TTY."),
      Command.new("lint #{MODE}",
        "Check the application against Caramel's RFC-0008 rule set in .ameba.yml; " \
        "MRDP unless stdout is a TTY."),
      Command.new("format",
        "Format the application's Crystal files with the pinned compiler's formatter."),
      Command.new("routes [FILTER]",
        "List routes with their contracts; FILTER keeps routes whose method, " \
        "path or action contains it (any case)."),
      Command.new("expand FILE:LINE:COL",
        "Print the plain Crystal that the macro call at FILE:LINE:COL expands to."),
      Command.new("make resource NAME FIELD:TYPE... [--plural=NAME] [--only=ACTIONS]",
        "Generate a SugarORM schema, migration, actions, views, routes and specs; " \
        "FIELD:TYPE:server marks a field the server sets, " \
        "kept out of forms and contracts, " \
        ":unique adds a unique index and changeset constraint, " \
        "and :url validates an http or https URL entered in a URL input. " \
        "--only=create,show,index,new keeps the listed actions " \
        "of index, show, new, create, edit, update and destroy; " \
        "create and show are required, and edit needs new and update."),
      Command.new("migrate [--dev-override] #{MODE}",
        "Lint and apply pending migrations, then report schema drift read-only."),
      Command.new("seed", "Load db/seeds.cr into the development database."),
      Command.new("corretto [SPEC_PATHS...] " \
                  "[--concurrency=1..#{Latte::Postgres::MAX_TEST_WORKERS}]",
        "Run specs in isolated Latte test databases with synchronous queue drains."),
      Command.new("db dump", "Save a backup of the development database."),
      Command.new("db restore FILE",
        "Restore the development database from FILE after a safety backup."),
      Command.new("db diff --name NAME [--dev-override] #{MODE}",
        "Derive migrations from the declared schema and prove them on a scratch branch."),
      Command.new("db branch create NAME",
        "Clone the development database into branch NAME and print its connection URL."),
      Command.new("db branch list", "List this project's database branches."),
      Command.new("db branch delete NAME", "Drop database branch NAME."),
      Command.new("logs [app|compiler] [--follow]", "Show the development app or compiler log."),
      Command.new("services [status|start|stop]",
        "Show, start or stop Latte's PostgreSQL, DNS and HTTPS services.",
        project: false),
      Command.new("sites", "List the sites registered with Latte.", project: false),
      Command.new("sites remove NAME",
        "Unregister site NAME, keeping its files, databases and credentials.",
        project: false),
      Command.new("installations [list]",
        "List the Caramel releases installed on this Mac.",
        project: false),
      Command.new("installations install VERSION",
        "Clone, build and register the tagged release VERSION, " \
        "reusing this toolchain when the release pins the same one; " \
        "if VERSION is installed, build what it lacks, such as its linter.",
        project: false),
      Command.new("installations register",
        "Register this checkout for projects pinned to its version; " \
        "~/.local/bin/frappe and latte run the newest installed release.",
        project: false),
      Command.new("installations remove VERSION",
        "Forget the installation registered for VERSION; " \
        "the launchers move to the newest remaining release.",
        project: false),
      Command.new("doctor",
        "Check the toolchain, this Caramel installation, dependencies, " \
        "local configuration and Latte services."),
      Command.new("open", "Open the application's HTTPS origin in the browser."),
      Command.new("lsp crystalline|ameba-ls [SERVER_ARGS...]",
        "Run a pinned language server for this project on stdio.",
        passthrough: true),
      Command.new("lsp install", "Build the pinned language servers.", project: false),
    ]

    def self.parse(args : Array(String)) : Invocation
      first = args.first? || raise Usage.new("missing command", "frappe", [TABLE.first])
      family = TABLE.select { |command| command.words.first == first }
      if family.empty?
        suggestion = nearest(first, TABLE.map(&.words.first).uniq!)
        intended = suggestion ? TABLE.select(&.words.first.==(suggestion)) : [] of Command
        message = "unknown command #{first}"
        raise Usage.new(message, "frappe #{first}", intended, suggestion)
      end
      depth = family.max_of { |command| shared(command.words, args) }
      group = family.select { |command| shared(command.words, args) == depth }
      subject = "frappe #{args[0, depth].join(' ')}"
      if command = group.find(&.words.size.==(depth))
        begin
          return bind(command, args[depth..])
        rescue ex : Usage
          raise ex if group.size == 1
          # `sites bogus`: the word after the prefix may be a mistyped subcommand.
          word = args[depth]?
          suggestion = ex.suggestion || (word && nearest(word, group.compact_map(&.words[depth]?)))
          raise Usage.new(ex.message || "invalid arguments", subject, group, suggestion)
        end
      end
      if word = args[depth]?
        message = "unknown #{subject.lchop("frappe ")} subcommand #{word}"
        subcommands = group.compact_map(&.words[depth]?).uniq!
        raise Usage.new(message, subject, group, nearest(word, subcommands))
      end
      raise Usage.new("#{subject} needs a subcommand", subject, group)
    end

    # The commands whose words start with `words`, for `frappe db --help`.
    def self.matching(words : Array(String)) : Array(Command)
      TABLE.select do |command|
        command.words.size >= words.size && command.words[0, words.size] == words
      end
    end

    # Whether `args` name a project command, which a project pinned to another
    # Caramel release must run through that release's Frappé. Malformed
    # project commands also dispatch, so the pinned release validates them.
    def self.project?(args : Array(String)) : Bool
      family = TABLE.select { |command| command.words.first == args.first? }
      return false if family.empty?
      matched = family
        .select { |command| shared(command.words, args) == command.words.size }
        .max_by?(&.words.size)
      matched ? matched.project? : family.any?(&.project?)
    end

    # Splits on top-level spaces; `[...]` groups and a required `--flag VALUE`
    # each stay one token.
    def self.tokens(syntax : String) : Array(String)
      tokens = [] of String
      current = String::Builder.new
      depth = 0
      syntax.each_char do |char|
        depth += 1 if char == '['
        depth -= 1 if char == ']'
        if char == ' ' && depth == 0
          tokens << current.to_s unless current.empty?
          current = String::Builder.new
        else
          current << char
        end
      end
      tokens << current.to_s unless current.empty?
      tokens.each_with_object([] of String) do |token, merged|
        previous = merged.last?
        if previous && token.matches?(/\A[A-Z]/) && previous.starts_with?("--") &&
           !previous.includes?(' ') && !previous.includes?('=')
          merged[-1] = "#{previous} #{token}"
        else
          merged << token
        end
      end
    end

    def self.nearest(word : String, candidates : Enumerable(String)) : String?
      best = candidates.min_by? { |candidate| distance(word, candidate) }
      best if best && best != word && distance(word, best) <= (best.size // 3).clamp(1, 3)
    end

    def self.distance(left : String, right : String) : Int32
      previous = (0..right.size).to_a
      left.each_char.with_index(1) do |a, row|
        current = [row]
        right.each_char.with_index(1) do |b, column|
          substitution = previous[column - 1] + (a == b ? 0 : 1)
          current << {current[column - 1] + 1, previous[column] + 1, substitution}.min
        end
        previous = current
      end
      previous.last
    end

    private def self.shared(words : Array(String), args : Array(String)) : Int32
      count = 0
      while count < words.size && words[count] == args[count]?
        count += 1
      end
      count
    end

    # ameba:disable Metrics/CyclomaticComplexity -- one branch per argument form
    private def self.bind(command : Command, args : Array(String)) : Invocation
      values = {} of String => String
      lists = {} of String => Array(String)
      given = Set(String).new
      fail = ->(message : String, suggestion : String?) do
        Usage.new(message, "frappe #{command.name}", [command], suggestion)
      end
      position = 0
      index = 0
      while index < args.size
        arg = args[index]
        index += 1
        slot = command.positionals[position]?
        if command.passthrough? && slot && slot.repeat
          lists[slot.name] = args[(index - 1)..]
          break
        end
        if arg.size > 1 && arg.starts_with?('-')
          name, equals, value = arg.partition('=')
          flag = command.flags.find(&.names.includes?(name))
          unless flag
            spellings = command.flags.flat_map(&.names)
            raise fail.call("unknown option #{name}", nearest(name, spellings))
          end
          if flag.names.any? { |other| given.includes?(other) }
            repeated = if flag.names.size > 1
                         "#{flag.names.join(" and ")} exclude each other"
                       else
                         "#{name} is given more than once"
                       end
            raise fail.call(repeated, nil)
          end
          if placeholder = flag.value
            if flag.equals
              if equals.empty? || value.empty?
                raise fail.call("#{name} needs a value: #{name}=#{placeholder}", nil)
              end
            else
              missing = "#{name} needs a value: #{name} #{placeholder}"
              raise fail.call(missing, nil) unless equals.empty?
              value = args[index]?
              if value.nil? || value.empty? || value.starts_with?('-')
                raise fail.call(missing, nil)
              end
              index += 1
            end
            if range = placeholder.match(/\A(\d+)\.\.(\d+)\z/)
              number = value.to_i?
              unless number && value.matches?(/\A\d+\z/) &&
                     (range[1].to_i..range[2].to_i).includes?(number)
                message = "#{name} must be a whole number from #{range[1]} to #{range[2]}"
                raise fail.call(message, nil)
              end
            end
            values[name] = value
          else
            raise fail.call("#{name} takes no value", nil) unless equals.empty?
          end
          given << name
        else
          raise fail.call("unexpected argument #{arg.inspect}", nil) unless slot
          raise fail.call("empty argument for #{slot.name}", nil) if arg.empty?
          if (choices = slot.choices) && !choices.includes?(arg)
            raise fail.call("unknown #{arg}; expected #{slot.name}", nearest(arg, choices))
          end
          if slot.repeat
            (lists[slot.name] ||= [] of String) << arg
          else
            values[slot.name] = arg
            position += 1
          end
        end
      end
      command.positionals.each do |positional|
        next if positional.optional
        next if values.has_key?(positional.name) || lists.has_key?(positional.name)
        raise fail.call("missing #{positional.name}", nil)
      end
      command.flags.each do |option|
        next if option.optional
        next if option.names.any? { |spelling| given.includes?(spelling) }
        raise fail.call("missing #{option.names.first} #{option.value}", nil)
      end
      Invocation.new(command, values, lists, given)
    end
  end
end
