require "./migration"

module SugarORM
  # Zero-lock rules over migration SQL. The migrator runs them
  # over every pending migration before it executes any statement.
  module Linter
    IDENTIFIER = %q((?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*))
    NAME       = "(?:#{IDENTIFIER}\\.)?(#{IDENTIFIER})"
    ANNOTATION = /^\s*--\s*caramel:allow-(drop|rename)\s+([^\s.]+)\.(\S+)\s*$/

    # Optional clauses of the statements below, each with its trailing space.
    IF_EXISTS     = %q((?:IF\s+EXISTS\s+)?)
    IF_NOT_EXISTS = %q((?:IF\s+NOT\s+EXISTS\s+)?)
    ONLY          = %q((?:ONLY\s+)?)
    COLUMN        = %q((?:COLUMN\s+)?)
    PERSISTENCE   = %q((?:(?:GLOBAL|LOCAL)\s+)?(?:(?:TEMP|TEMPORARY|UNLOGGED)\s+)?)
    # ADD starts a column unless a table constraint follows it.
    NOT_CONSTRAINT = %q((?!(?:CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN|EXCLUDE)\b))
    # `[IF NOT EXISTS] [name] ON [ONLY] table` in CREATE INDEX: captures the
    # index name and the table.
    INDEX_ON = "#{IF_NOT_EXISTS}(?:(#{IDENTIFIER})\\s+)?ON\\s+#{ONLY}#{NAME}"

    CREATE_TABLE  = /\ACREATE\s+#{PERSISTENCE}TABLE\s+#{IF_NOT_EXISTS}#{NAME}/i
    CREATE_INDEX  = /\ACREATE\s+(?:UNIQUE\s+)?INDEX\s+(CONCURRENTLY\s+)?#{INDEX_ON}/i
    DROP_INDEX    = /\ADROP\s+INDEX\s+CONCURRENTLY\s/i
    REINDEX       = /\AREINDEX\s.*\bCONCURRENTLY\b/i
    ALTER_TABLE   = /\AALTER\s+TABLE\s+#{IF_EXISTS}#{ONLY}#{NAME}\s+(.+)\z/im
    VALIDATE      = /\AVALIDATE\s+CONSTRAINT\s+(#{IDENTIFIER})\s*;?\z/i
    ADD_COLUMN    = /\AADD\s+#{NOT_CONSTRAINT}#{COLUMN}#{IF_NOT_EXISTS}(#{IDENTIFIER})\s/i
    DROP_COLUMN   = /\ADROP\s+(?!CONSTRAINT\b)#{COLUMN}#{IF_EXISTS}(#{IDENTIFIER})/i
    RENAME_COLUMN = /\ARENAME\s+(?!(?:TO|CONSTRAINT)\b)#{COLUMN}(#{IDENTIFIER})\s+TO\s/i
    NOT_NULL      = /\bNOT\s+NULL\b/i
    DEFAULTED     = /\b(?:DEFAULT|GENERATED)\b/i

    record Violation,
      rule : String,
      message : String,
      remediation : String,
      migration : String,
      statement : String,
      file : String do
      def to_s(io : IO) : Nil
        io << "LINT " << rule << ": " << message << '\n'
        io << "  in " << migration << ":\n"
        statement.strip.each_line { |line| io << "  │ " << line << '\n' }
        io << "  Remediation: " << remediation
      end

      # MRDP, with the migration file relative to `root`.
      def to_mrdp(io : IO, root : String = Dir.current) : Nil
        at = file.starts_with?(root + "/") ? file[(root.size + 1)..] : file
        io << "ERR LINT_" << rule.upcase.tr("-", "_") << " at " << at << '\n'
        io << "MSG: " << message << '\n'
        io << "FIX: " << remediation << '\n'
      end
    end

    class Refused < Exception
      getter violations : Array(Violation)

      def initialize(@violations : Array(Violation),
                     dev_override : Bool,
                     environment : String)
        note = if dev_override
                 "--dev-override was ignored: it applies only when " \
                 "CARAMEL_ENV=development (current: #{environment})."
               else
                 "Migration refused. In development only, " \
                 "--dev-override downgrades these violations to warnings."
               end
        super((@violations.map(&.to_s) << note).join("\n\n"))
      end

      def to_mrdp(root : String = Dir.current) : String
        String.build { |io| @violations.each(&.to_mrdp(io, root)) }
      end
    end

    def self.environment : String
      ENV["CARAMEL_ENV"]? || "production"
    end

    def self.lint(migrations : Array(Migration)) : Array(Violation)
      migrations.flat_map { |migration| lint(migration) }
    end

    # ameba:disable Metrics/CyclomaticComplexity -- one branch per DDL statement kind
    def self.lint(migration : Migration) : Array(Violation)
      label = "migration #{migration.version} (#{migration.name})"
      allowed = migration.statements.flat_map { |statement| annotations(statement) }.to_set
      created = Set(String).new
      violations = [] of Violation
      migration.statements.each do |statement|
        code = code(statement)
        if match = code.match(CREATE_TABLE)
          created << identifier(match[1])
        elsif (match = code.match(CREATE_INDEX)) && match[1]?.nil? &&
              !created.includes?(identifier(match[3]))
          table = identifier(match[3])
          violations << Violation.new(
            rule: "concurrent-index",
            message: "CREATE INDEX on existing table #{table} " \
                     "blocks its writes while the index builds.",
            remediation: "use CREATE INDEX CONCURRENTLY in a migration of its own; " \
                         "frappe db diff emits it that way.",
            migration: label,
            statement: statement,
            file: migration.file,
          )
        elsif match = code.match(ALTER_TABLE)
          table = identifier(match[1])
          actions(match[2]).each do |action|
            if (column = action.match(ADD_COLUMN)) && !created.includes?(table) &&
               action.matches?(NOT_NULL) && !action.matches?(DEFAULTED)
              violations << Violation.new(
                rule: "not-null-default",
                message: "ADD COLUMN #{identifier(column[1])} NOT NULL " \
                         "without a DEFAULT fails on a populated #{table} table.",
                remediation: "give the column a DEFAULT, or add it nullable, " \
                             "backfill it, and tighten it later.",
                migration: label,
                statement: statement,
                file: migration.file,
              )
            elsif (column = action.match(DROP_COLUMN)) &&
                  !allowed.includes?({"drop", table, identifier(column[1])})
              name = identifier(column[1])
              violations << Violation.new(
                rule: "destructive-column",
                message: "DROP COLUMN #{name} destroys the data in #{table}.#{name}.",
                remediation: "declare drop_column :#{name} in the schema " \
                             "and diff again; hand-written SQL needs the line " \
                             "-- caramel:allow-drop #{table}.#{name}",
                migration: label,
                statement: statement,
                file: migration.file,
              )
            elsif (column = action.match(RENAME_COLUMN)) &&
                  !allowed.includes?({"rename", table, identifier(column[1])})
              name = identifier(column[1])
              violations << Violation.new(
                rule: "destructive-column",
                message: "RENAME COLUMN #{name} breaks code " \
                         "that still reads #{table}.#{name}.",
                remediation: "declare renamed_from: :#{name} on the new field " \
                             "and diff again; hand-written SQL needs the line " \
                             "-- caramel:allow-rename #{table}.#{name}",
                migration: label,
                statement: statement,
                file: migration.file,
              )
            end
          end
        end
      end
      if concurrent = migration.statements.find { |statement| concurrent?(statement) }
        unless migration.statements.all? { |statement| online?(statement) }
          violations << Violation.new(
            rule: "mixed-concurrency",
            message: "CONCURRENTLY statements cannot run inside the transaction " \
                     "this migration's other statements need.",
            remediation: "move the CONCURRENTLY statements into a migration " \
                         "of their own; frappe db diff splits them for you.",
            migration: label,
            statement: concurrent,
            file: migration.file,
          )
        end
      end
      violations
    end

    # Downgrades violations to warnings only for --dev-override in development;
    # test, production and staging (which runs as production) always refuse.
    def self.enforce(violations : Array(Violation),
                     dev_override : Bool,
                     environment : String = self.environment,
                     warnings : IO = STDERR) : Nil
      return if violations.empty?
      overridden = dev_override && environment == "development"
      raise Refused.new(violations, dev_override, environment) unless overridden
      violations.each { |violation| warnings.puts("WARN (--dev-override) #{violation}") }
    end

    # CONCURRENTLY statements must run outside a transaction block.
    def self.concurrent?(statement : String) : Bool
      code = code(statement)
      return true if code.match(CREATE_INDEX).try(&.[1]?)
      code.matches?(DROP_INDEX) || code.matches?(REINDEX)
    end

    # Online statements may run in autocommit: CONCURRENTLY statements and
    # constraint validation, which must not share the transaction that added
    # the NOT VALID constraint, or its lock is held for the whole scan.
    def self.online?(statement : String) : Bool
      return true if concurrent?(statement)
      match = code(statement).match(ALTER_TABLE)
      !!match && actions(match[2]).all?(&.matches?(VALIDATE))
    end

    # The `{table, constraint}` a statement validates, when it is a lone
    # `ALTER TABLE … VALIDATE CONSTRAINT …`.
    def self.validated_constraint(statement : String) : {String, String}?
      match = code(statement).match(ALTER_TABLE) || return
      actions = actions(match[2])
      return unless actions.size == 1
      validate = actions.first.match(VALIDATE) || return
      {identifier(match[1]), identifier(validate[1])}
    end

    # The index a CREATE INDEX CONCURRENTLY statement builds, when it names one.
    def self.concurrent_index(statement : String) : String?
      match = code(statement).match(CREATE_INDEX)
      match[2]?.try { |name| identifier(name) } if match && match[1]?
    end

    def self.identifier(token : String) : String
      token.starts_with?('"') ? token[1...-1].gsub("\"\"", "\"") : token.downcase
    end

    private def self.annotations(statement : String) : Array(Tuple(String, String, String))
      statement.lines.compact_map do |line|
        line.match(ANNOTATION).try { |match| {match[1], match[2], match[3]} }
      end
    end

    # Statement text without comments and with collapsed whitespace; quoted
    # literals and identifiers are kept intact.
    # ameba:disable Metrics/CyclomaticComplexity -- a single-pass SQL tokenizer
    private def self.code(statement : String) : String
      chars = statement.chars
      text = String.build do |io|
        index = 0
        quote = nil
        while index < chars.size
          char = chars[index]
          following = chars[index + 1]?
          if quote
            quote = nil if char == quote
          elsif char == '\'' || char == '"'
            quote = char
          elsif char == '-' && following == '-'
            while index < chars.size && chars[index] != '\n'
              index += 1
            end
            next
          elsif char == '/' && following == '*'
            index += 2
            while index < chars.size && !(chars[index] == '*' && chars[index + 1]? == '/')
              index += 1
            end
            index += 2
            io << ' '
            next
          end
          io << char
          index += 1
        end
      end
      text.gsub(/\s+/, " ").strip.rchop(';').rstrip
    end

    # Splits ALTER TABLE actions on top-level commas.
    private def self.actions(text : String) : Array(String)
      actions = [] of String
      depth = 0
      quote = nil
      start = 0
      text.each_char_with_index do |char, index|
        if quote
          quote = nil if char == quote
        elsif char == '\'' || char == '"'
          quote = char
        elsif char == '('
          depth += 1
        elsif char == ')'
          depth -= 1
        elsif char == ',' && depth == 0
          actions << text[start...index].strip
          start = index + 1
        end
      end
      actions << text[start..].strip
      actions.reject(&.empty?)
    end
  end
end
