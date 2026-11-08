require "./project"
require "../latte/postgres"

module Caramel::Frappe
  # Frappé's command line, stated once. Help, family help, completion, usage,
  # argument validation, project dispatch and `frappe agent-manifest` all read TABLE.
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
      # A family run with no subcommand: its message is a statement, not a complaint.
      getter? bare : Bool

      def initialize(message : String,
                     @subject : String,
                     @commands : Array(Command) = [] of Command,
                     @suggestion : String? = nil,
                     @bare : Bool = false)
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
      # The one line that lists show: capitalised, no trailing period.
      getter brief : String
      # Invocations without the leading `frappe `, as plain strings: the website
      # reads them from this file, and a spec proves each parses.
      getter examples : Array(String)
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
                     @brief : String,
                     @examples : Array(String) = [] of String,
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
      Command.new("help [COMMAND...]",
        "Print every command grouped by task, or, given a command's words such as db branch, " \
        "its usage and examples or its subcommands.",
        brief: "List commands, or show one command's help",
        examples: ["help make resource", "help db"],
        project: false),
      Command.new("version", "Print the Frappé version.",
        brief: "Print the Frappé version",
        project: false),
      Command.new("completion zsh|bash|fish",
        "Print the shell completion script for zsh, bash or fish; it completes commands, " \
        "subcommands, options and their choices. For zsh, add source <(frappe completion zsh) " \
        "to ~/.zshrc after compinit; for bash, add source <(frappe completion bash) to " \
        "~/.bashrc; for fish, run frappe completion fish > ~/.config/fish/completions/frappe.fish.",
        brief: "Print a shell completion script for zsh, bash or fish",
        examples: ["completion zsh", "completion fish"],
        project: false),
      Command.new("agent-manifest",
        "Print the release's version and the addresses of its documentation and guides, " \
        "this strict command list and the MRDP diagnostic grammar for coding agents.",
        brief: "Print every command in full, for coding agents",
        project: false),
      Command.new("new NAME",
        "Create the application ./NAME, install its locked dependencies " \
        "and register it with Latte.",
        brief: "Create a new application and set it up",
        examples: ["new my-app"],
        project: false),
      Command.new("setup [--no-migrate]",
        "Install locked dependencies, register this project with Latte and apply " \
        "pending migrations to the development database, preserving existing files; " \
        "--no-migrate leaves the database unchanged.",
        brief: "Install dependencies and prepare the database",
        examples: ["setup", "setup --no-migrate"]),
      Command.new("dev [--no-open] [--branch NAME]",
        "Build, serve and reload the app at its HTTPS origin; " \
        "--branch runs it against database branch NAME.",
        brief: "Build, serve and reload the app in your browser",
        examples: ["dev", "dev --branch spike"]),
      Command.new("check #{MODE}",
        "Run the Tier-1 type check (crystal build --no-codegen) " \
        "and report diagnostics; MRDP unless stdout is a TTY.",
        brief: "Type-check the application",
        examples: ["check", "check --agent"]),
      Command.new("lint #{MODE}",
        "Check the application against Caramel's rule set in .ameba.yml; " \
        "MRDP unless stdout is a TTY.",
        brief: "Lint the application against Caramel's rules",
        examples: ["lint", "lint --agent"]),
      Command.new("format",
        "Format the application's Crystal files with the pinned compiler's formatter.",
        brief: "Format the application's Crystal files"),
      Command.new("routes [FILTER]",
        "List routes with their contracts; FILTER keeps routes whose method, " \
        "path or action contains it (any case).",
        brief: "List routes with their contracts",
        examples: ["routes", "routes books"]),
      Command.new("requirements [ID]",
        "List the requirement ids the SweetTalk domain declares, each with the never, " \
        "always, specification and unit lines that assure it; ID shows one.",
        brief: "List the requirements the domain assures",
        examples: ["requirements"]),
      Command.new("glossary [--json]",
        "Print the SweetTalk domain's detailed glossary as Markdown: each term's meaning, " \
        "a value's bounds and words, an aggregate's states and moves, an event's handlers " \
        "in the order they run, a unit's changes: and locks:; --json prints the document.",
        brief: "Print the domain's glossary",
        examples: ["glossary", "glossary --json"]),
      Command.new("contexts [--mermaid]",
        "Print the SweetTalk context map: each context and kernel with what it depends on, " \
        "reacts to, shares and calls; --mermaid prints it as a Mermaid flowchart.",
        brief: "Print the domain's context map",
        examples: ["contexts", "contexts --mermaid"]),
      Command.new("words [WORD] [--json]",
        "Print SweetTalk's vocabulary as its macros state it, with no application needed: " \
        "every word with its kind and summary, or WORD's usage, options, one example " \
        "that compiles and its guide section; an unknown WORD names the nearest; " \
        "--json prints the same as JSON.",
        brief: "Look up SweetTalk's vocabulary, no app needed",
        examples: ["words", "words context"],
        project: false),
      Command.new("expand FILE:LINE:COL",
        "Print the plain Crystal that the macro call at FILE:LINE:COL expands to; " \
        "where none expands, the call whose block encloses it, such as " \
        "`contract` for a `field`, and say which.",
        brief: "Show the plain Crystal a macro call expands to",
        examples: ["expand app/actions/books/show.cr:3:5"]),
      Command.new("make resource NAME FIELD:TYPE... " \
                  "[--plural=NAME] [--only=ACTIONS] [--central] [--int64]",
        "Generate a SugarORM schema, migration, actions, views, routes and specs; " \
        "FIELD:TYPE:server marks a field the server sets, " \
        "kept out of forms and contracts, " \
        ":unique adds a unique index and changeset constraint, " \
        "and :url validates an http or https URL entered in a URL input. " \
        "--only=create,show,index,new keeps the listed actions " \
        "of index, show, new, create, edit, update and destroy; " \
        "create and show are required, and edit needs new and update. " \
        "In a multi-tenant application a resource belongs to the tenant " \
        "unless --central is given. " \
        "--int64 keys it by an Int64 the database assigns instead of a UUID.",
        brief: "Generate a schema, migration, actions, views and specs",
        examples: ["make resource Book title:string author:string",
                   "make resource Note body:string --only=create,show,index,new"]),
      Command.new("make locale CODE",
        "Add the locale CODE, such as fr or pt-BR: create app/locales/CODE.cr; " \
        "on first use also app/locales/en.cr and the i18n lines in " \
        "config/application.cr, after which frappe make resource writes translated views.",
        brief: "Add a locale and translate generated views",
        examples: ["make locale fr"]),
      Command.new("make tenancy MODEL [--int64]",
        "Make the application multi-tenant with MODEL, such as Account, as the tenant: " \
        "its schema, migration, sign-up page at /PLURAL/new and home at /SLUG, " \
        "require \"caramel/tenancy\" and the tenant block in config/routes.cr; " \
        "frappe make resource then writes resources that belong to a tenant. " \
        "--int64 keys it by an Int64 the database assigns instead of a UUID.",
        brief: "Make the application multi-tenant",
        examples: ["make tenancy Account"]),
      Command.new("make domain NAME CONTEXT --means=TEXT [--central]",
        "Start a SweetTalk domain: app/domain/NAME.cr with its first context CONTEXT, " \
        "which means TEXT, and spec/domain/NAME_spec.cr; on first use also " \
        "require \"caramel/sweet_talk\", require \"../app/domain/*\" and SweetTalk.boot " \
        "in config/application.cr. When the application has no SweetTalk skill for agents, " \
        "it also writes .claude/skills/sweettalk/SKILL.md. In a multi-tenant application " \
        "the domain names the tenant, and --central makes the context one every tenant " \
        "shares.",
        brief: "Start a SweetTalk domain with its first context",
        examples: ["make domain Library Lending --means=\"Members borrow and return books\""]),
      Command.new("translations",
        "List the keys each locale still takes from the default locale; " \
        "exits 1 while any is missing.",
        brief: "List keys a locale still takes from the default"),
      Command.new("migrate [--dev-override] #{MODE}",
        "Lint and apply pending migrations, then report schema drift read-only.",
        brief: "Apply pending migrations and report drift",
        examples: ["migrate", "migrate --dev-override"]),
      Command.new("seed", "Load db/seeds.cr into the development database.",
        brief: "Load db/seeds.cr into the development database"),
      Command.new("build",
        "Build the Linux release artifact in a container: a static linux/amd64 binary and " \
        "public/ in .caramel/build/; refuses uncommitted changes and prints the artifact's path.",
        brief: "Build the Linux release artifact in a container"),
      Command.new("corretto [SPEC_PATHS...] " \
                  "[--concurrency=1..#{Latte::Postgres::MAX_TEST_WORKERS}]",
        "Run specs in isolated Latte test databases with synchronous queue drains.",
        brief: "Run specs in isolated test databases",
        examples: ["corretto", "corretto spec/requests/books_spec.cr", "corretto --concurrency=4"]),
      Command.new("db dump", "Save a backup of the development database.",
        brief: "Save a backup of the development database"),
      Command.new("db restore FILE",
        "Restore the development database from FILE after a safety backup.",
        brief: "Restore the database from a backup file",
        examples: ["db restore backup.dump"]),
      Command.new("db diff --name NAME [--dev-override] #{MODE}",
        "Derive migrations from the declared schema and prove them on a scratch branch.",
        brief: "Derive migrations from the declared schema",
        examples: ["db diff --name add_isbn_to_books"]),
      Command.new("db branch create NAME",
        "Clone the development database into branch NAME and print its connection URL.",
        brief: "Clone the development database into a branch",
        examples: ["db branch create spike"]),
      Command.new("db branch list", "List this project's database branches.",
        brief: "List this project's database branches"),
      Command.new("db branch delete NAME", "Drop database branch NAME.",
        brief: "Drop a database branch",
        examples: ["db branch delete spike"]),
      Command.new("db diagnose",
        "Report database health: connections, locks, cache hits, unused indexes " \
        "and the slowest statements.",
        brief: "Report connections, locks, cache hits and slow queries"),
      Command.new("logs [app|compiler|access] [--follow]",
        "Show the development app or compiler log, or Caddy's access log.",
        brief: "Show the app, compiler or access log",
        examples: ["logs", "logs compiler --follow"]),
      Command.new("traces [--errors] [--slow=MS] [--limit=N] #{MODE}",
        "List the development session's recent requests, jobs and schedule runs, " \
        "newest first.",
        brief: "List recent requests, jobs and schedule runs",
        examples: ["traces --errors", "traces --slow=200 --limit=5"]),
      Command.new("trace REF [--md]",
        "Show one development trace: its summary, queries, logs and error. " \
        "REF is last, last-error, or a prefix of a trace id, a request id or an error " \
        "fingerprint.",
        brief: "Show one trace: queries, logs and error",
        examples: ["trace last", "trace last-error --md"]),
      Command.new("errors #{MODE}",
        "List development runtime errors and repeated queries, grouped.",
        brief: "List runtime errors and repeated queries",
        examples: ["errors", "errors --agent"]),
      Command.new("services [status|start|stop]",
        "Show, start or stop Latte's PostgreSQL, DNS and HTTPS services.",
        brief: "Show, start or stop PostgreSQL, DNS and HTTPS",
        examples: ["services", "services start"],
        project: false),
      Command.new("sites", "List the sites registered with Latte.",
        brief: "List the sites registered with Latte",
        project: false),
      Command.new("sites remove NAME",
        "Unregister site NAME, keeping its files, databases, credentials, logs and backups.",
        brief: "Unregister a site, keeping its files and data",
        examples: ["sites remove my-app"],
        project: false),
      Command.new("installations [list]",
        "List the Caramel releases installed on this Mac.",
        brief: "List the Caramel releases on this Mac",
        examples: ["installations"],
        project: false),
      Command.new("installations install VERSION",
        "Clone, build and register the tagged release VERSION, " \
        "reusing this toolchain when the release pins the same one; " \
        "if VERSION is installed, build what it lacks, such as its linter.",
        brief: "Clone, build and register a release",
        examples: ["installations install 0.22.0"],
        project: false),
      Command.new("installations register",
        "Register this checkout for projects pinned to its version; " \
        "~/.local/bin/frappe and latte run the newest installed release.",
        brief: "Register this checkout for its version",
        project: false),
      Command.new("installations remove VERSION",
        "Forget the installation registered for VERSION; " \
        "the launchers move to the newest remaining release.",
        brief: "Forget an installed release",
        examples: ["installations remove 0.21.0"],
        project: false),
      Command.new("doctor",
        "Check the toolchain, this Caramel installation, dependencies, local configuration, " \
        "Latte services, trusted HTTPS and the port relay.",
        brief: "Check your toolchain, Latte and local setup"),
      Command.new("open",
        "Open the application's HTTPS origin in the browser; while frappe dev runs, a " \
        "single-use link signs the browser in to the toolbar and inspector.",
        brief: "Open the running app in your browser"),
      Command.new("lsp crystalline|ameba-ls [SERVER_ARGS...]",
        "Run a pinned language server for this project on stdio.",
        brief: "Run a language server for this project on stdio",
        examples: ["lsp crystalline"],
        passthrough: true),
      Command.new("lsp install", "Build the pinned language servers.",
        brief: "Build the pinned language servers",
        project: false),
    ]

    # `frappe help`'s rows, in the order a newcomer needs them: each name is a
    # command's first word, listed once (commands_spec holds every first word to one group).
    record Group, title : String, names : Array(String)

    # The line for each run of words that two or more commands share, shown in help,
    # family help and completion; commands_spec holds this to exactly those runs.
    FAMILIES = {
      "make"          => "Generate code: resource, locale, tenancy, domain",
      "db"            => "Dump, restore, diff, branch or diagnose the database",
      "db branch"     => "Create, list or delete database branches",
      "sites"         => "List or unregister the sites Latte serves",
      "installations" => "List, install, register or remove Caramel releases",
      "lsp"           => "Run or build the language servers",
    }

    GROUPS = [
      Group.new("GET STARTED", %w[new setup dev open doctor]),
      Group.new("WRITE YOUR APP", %w[make routes expand translations]),
      Group.new("CHECK AND TEST", %w[check lint format corretto]),
      Group.new("DATABASE", %w[migrate seed db]),
      Group.new("DEBUG A RUNNING APP", %w[logs traces trace errors]),
      Group.new("SWEETTALK DOMAIN", %w[words requirements glossary contexts]),
      Group.new("SHIP", %w[build]),
      Group.new("LATTE AND THIS MAC", %w[services sites installations lsp]),
      Group.new("ABOUT FRAPPÉ", %w[help version completion agent-manifest]),
    ]

    def self.parse(args : Array(String)) : Invocation
      first = args.first? || raise Usage.new("missing command", "frappe", [TABLE.first])
      family = TABLE.select { |command| command.words.first == first }
      raise unknown(first) if family.empty?
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
      # `frappe db --human` names no subcommand: the mode flags select the output only.
      if (word = args[depth]?) && !{"--agent", "--human"}.includes?(word)
        message = "unknown #{subject.lchop("frappe ")} subcommand #{word}"
        subcommands = group.compact_map(&.words[depth]?).uniq!
        raise Usage.new(message, subject, group, nearest(word, subcommands))
      end
      raise Usage.new("#{subject} needs a subcommand", subject, group, bare: true)
    end

    # The error for a first word that names no command, with the nearest command's
    # family as the intended commands.
    def self.unknown(first : String) : Usage
      suggestion = nearest(first, TABLE.map(&.words.first).uniq!)
      intended = suggestion ? TABLE.select(&.words.first.==(suggestion)) : [] of Command
      Usage.new("unknown command #{first}", "frappe #{first}", intended, suggestion)
    end

    # The commands whose words start with `words`, for `frappe db --help`.
    def self.matching(words : Array(String)) : Array(Command)
      TABLE.select do |command|
        command.words.size >= words.size && command.words[0, words.size] == words
      end
    end

    # The line for a run of command words: a family's, or a single command's.
    def self.brief(words : Array(String)) : String
      FAMILIES[words.join(' ')]? || TABLE.find!(&.words.==(words)).brief
    end

    # The longest run of leading words that all of `commands` share.
    def self.prefix(commands : Array(Command)) : Array(String)
      first = commands.first.words
      count = first.size
      commands.each { |command| count = {count, shared(first, command.words)}.min }
      first[0, count]
    end

    # The longest leading run of `args` that names a command or family, or nil.
    def self.help_words(args : Array(String)) : Array(String)?
      args.size.downto(1) do |size|
        words = args[0, size]
        return words unless matching(words).empty?
      end
      nil
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
