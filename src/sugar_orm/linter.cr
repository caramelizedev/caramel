require "./migration"

module SugarORM
  # Zero-lock rules over migration SQL. The migrator runs them
  # over every pending migration before it executes any statement.
  #
  # `-- caramel:allow <rule> <subject>` on a line of its own exempts one
  # `{rule, subject}` for the migration: the subject is the table, `table.column`,
  # or, for concurrent-drop-index, the index. The older `-- caramel:allow-drop
  # table.column` and `-- caramel:allow-rename table.column` lines name the
  # destructive-column rule. A relation the migration creates is exempt from the
  # rules that protect rows and readers, because it has neither.
  module Linter
    IDENTIFIER = %q((?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*))
    NAME       = "(?:#{IDENTIFIER}\\.)?(#{IDENTIFIER})"
    ANNOTATION = /^\s*--\s*caramel:allow(?:-(drop|rename)|\s+([a-z-]+))\s+(\S+)\s*$/
    DOLLAR_TAG = /\A\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/
    # The tag of a dollar quote, captured so a back-reference can close it.
    DOLLAR_TAG_NAME = %q(([A-Za-z_][A-Za-z0-9_]*|))
    CONSTRAINT_KIND = %q((CHECK|FOREIGN\s+KEY|UNIQUE|PRIMARY\s+KEY))

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
    # `ALTER [COLUMN] name `: captures the column.
    ALTER_COLUMN = "ALTER\\s+#{COLUMN}(#{IDENTIFIER})\\s+"

    CREATE_TABLE = /\ACREATE\s+#{PERSISTENCE}TABLE\s+#{IF_NOT_EXISTS}#{NAME}/i
    CREATE_INDEX = /\ACREATE\s+(?:UNIQUE\s+)?INDEX\s+(CONCURRENTLY\s+)?#{INDEX_ON}/i
    DROP_INDEX   = /\ADROP\s+INDEX\s+(CONCURRENTLY\s+)?#{IF_EXISTS}#{NAME}/i
    REINDEX      = /\AREINDEX\s.*\bCONCURRENTLY\b/i
    DROP_TABLE   = /\ADROP\s+TABLE\s+#{IF_EXISTS}#{NAME}/i
    TRUNCATE     = /\ATRUNCATE\s+(?:TABLE\s+)?#{ONLY}#{NAME}/i
    UPDATE       = /\AUPDATE\s+#{ONLY}#{NAME}(?:\s+(?:AS\s+)?#{IDENTIFIER})?\s+SET\s/i
    DELETE       = /\ADELETE\s+FROM\s+#{ONLY}#{NAME}/i
    # `DO [LANGUAGE l] $tag$ body $tag$`: captures the tag and the body.
    DO_BLOCK      = /\ADO\s+(?:LANGUAGE\s+#{IDENTIFIER}\s+)?\$#{DOLLAR_TAG_NAME}\$(.*)\$\1\$/im
    ALTER_TABLE   = /\AALTER\s+TABLE\s+#{IF_EXISTS}#{ONLY}#{NAME}\s+(.+)\z/im
    VALIDATE      = /\AVALIDATE\s+CONSTRAINT\s+(#{IDENTIFIER})\s*;?\z/i
    RENAME_INDEX  = /\AALTER\s+INDEX\s+#{IF_EXISTS}#{NAME}\s+RENAME\s+TO\s+#{IDENTIFIER}\s*;?\z/i
    ADD_COLUMN    = /\AADD\s+#{NOT_CONSTRAINT}#{COLUMN}#{IF_NOT_EXISTS}(#{IDENTIFIER})\s/i
    DROP_COLUMN   = /\ADROP\s+(?!CONSTRAINT\b)#{COLUMN}#{IF_EXISTS}(#{IDENTIFIER})/i
    RENAME_COLUMN = /\ARENAME\s+(?!(?:TO|CONSTRAINT)\b)#{COLUMN}(#{IDENTIFIER})\s+TO\s/i
    RENAME_TABLE  = /\ARENAME\s+TO\s+(#{IDENTIFIER})/i
    ALTER_TYPE    = /\A#{ALTER_COLUMN}(?:SET\s+DATA\s+)?TYPE\s/i
    SET_NOT_NULL  = /\A#{ALTER_COLUMN}SET\s+NOT\s+NULL\b/i
    # `ADD [CONSTRAINT name] kind`: captures the name and the kind.
    ADD_CONSTRAINT = /\AADD\s+(?:CONSTRAINT\s+(#{IDENTIFIER})\s+)?#{CONSTRAINT_KIND}\b/i
    NOT_VALID      = /\bNOT\s+VALID\s*\z/i
    USING_INDEX    = /\bUSING\s+INDEX\s/i
    NOT_NULL       = /\bNOT\s+NULL\b/i
    DEFAULTED      = /\b(?:DEFAULT|GENERATED)\b/i
    # PL/pgSQL keywords after which a statement of a DO block may start.
    CONTROL = /\b(?:BEGIN|THEN|ELSE|LOOP)\b/i

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

    def self.lint(migration : Migration) : Array(Violation)
      Scan.new(migration).violations
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
      !!code.match(DROP_INDEX).try(&.[1]?) || code.matches?(REINDEX)
    end

    # Online statements may run in autocommit: CONCURRENTLY statements, index
    # renames, which take SHARE UPDATE EXCLUSIVE, and constraint validation,
    # which must not share the transaction that added the NOT VALID
    # constraint, or its lock is held for the whole scan.
    def self.online?(statement : String) : Bool
      return true if concurrent?(statement) || code(statement).matches?(RENAME_INDEX)
      match = code(statement).match(ALTER_TABLE)
      !!match && split(match[2], ',').all?(&.matches?(VALIDATE))
    end

    # The `{table, constraint}` a statement validates, when it is a lone
    # `ALTER TABLE … VALIDATE CONSTRAINT …`.
    def self.validated_constraint(statement : String) : {String, String}?
      match = code(statement).match(ALTER_TABLE) || return
      actions = split(match[2], ',')
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

    # The `{rule, subject}` pairs the annotation lines of a statement allow.
    protected def self.annotations(statement : String) : Array({String, String})
      statement.lines.compact_map do |line|
        match = line.match(ANNOTATION) || next
        {match[2]? || "destructive-column", match[3]}
      end
    end

    # Statement text without comments, with the whitespace between tokens
    # collapsed to one space. Quoted literals, identifiers and dollar-quoted
    # bodies are copied as written.
    protected def self.code(statement : String) : String
      chars = statement.chars
      text = String.build do |io|
        index = 0
        pending = false
        while index < chars.size
          if stop = quoted_end(statement, chars, index)
            io << ' ' if pending
            io << statement[index...stop]
            pending = false
            index = stop
          elsif stop = comment_end(chars, index)
            pending = true
            index = stop
          elsif chars[index].whitespace?
            pending = true
            index += 1
          else
            io << ' ' if pending
            io << chars[index]
            pending = false
            index += 1
          end
        end
      end
      text.strip.rchop(';').rstrip
    end

    # The index after the `--` or `/* */` comment that starts at *index*, or nil
    # when none does.
    private def self.comment_end(chars : Array(Char), index : Int32) : Int32?
      following = chars[index + 1]?
      if chars[index] == '-' && following == '-'
        stop = index + 2
        while stop < chars.size && chars[stop] != '\n'
          stop += 1
        end
        stop
      elsif chars[index] == '/' && following == '*'
        stop = index + 2
        while stop < chars.size && !(chars[stop] == '*' && chars[stop + 1]? == '/')
          stop += 1
        end
        {stop + 2, chars.size}.min
      end
    end

    # Splits *text* at each top-level *separator*: outside quotes and parentheses.
    protected def self.split(text : String, separator : Char) : Array(String)
      chars = text.chars
      pieces = [] of String
      depth = 0
      start = 0
      index = 0
      while index < chars.size
        if stop = quoted_end(text, chars, index)
          index = stop
          next
        end
        char = chars[index]
        depth += 1 if char == '('
        depth -= 1 if char == ')'
        if char == separator && depth == 0
          pieces << text[start...index].strip
          start = index + 1
        end
        index += 1
      end
      pieces << text[start..].strip
      pieces.reject(&.empty?)
    end

    # The index after the quoted literal, quoted identifier or dollar-quoted
    # body that starts at *index*, or nil when nothing quoted starts there. An
    # unclosed span runs to the end.
    private def self.quoted_end(text : String, chars : Array(Char), index : Int32) : Int32?
      case chars[index]
      when '$'       then dollar_end(text, chars, index)
      when '\'', '"' then quote_end(chars, index)
      end
    end

    # `$tag$ … $tag$`; a `$` after an identifier character belongs to the identifier.
    private def self.dollar_end(text : String, chars : Array(Char), index : Int32) : Int32?
      return if index > 0 && identifier_char?(chars[index - 1])
      tag = text[index..].match(DOLLAR_TAG).try(&.[0]) || return
      closing = text.index(tag, index + tag.size) || return chars.size
      closing + tag.size
    end

    # A backslash escapes the next character of an E'…' literal.
    private def self.quote_end(chars : Array(Char), index : Int32) : Int32
      quote = chars[index]
      escapes = quote == '\'' && index > 0 && chars[index - 1].in?('E', 'e') &&
                !(index > 1 && identifier_char?(chars[index - 2]))
      index += 1
      while index < chars.size
        if escapes && chars[index] == '\\'
          index += 2
        elsif chars[index] == quote
          return index + 1
        else
          index += 1
        end
      end
      chars.size
    end

    private def self.identifier_char?(char : Char) : Bool
      char.ascii_alphanumeric? || char == '_' || char == '$'
    end

    # One migration's pass over its statements, in order, so a relation created
    # earlier in the migration exempts the statements that follow.
    private class Scan
      getter violations = [] of Violation
      # The `{rule, subject}` pairs the migration's annotations allow.
      @allowed : Set({String, String})
      # Tables and indexes, which share one namespace.
      @created = Set(String).new
      @label : String

      def initialize(@migration : Migration)
        @label = "migration #{migration.version} (#{migration.name})"
        annotations = migration.statements.flat_map { |statement| Linter.annotations(statement) }
        @allowed = annotations.to_set
        migration.statements.each { |statement| scan(statement, Linter.code(statement)) }
        mixed_concurrency
      end

      # Checks one statement; false when it is of no kind the rules cover.
      private def scan(statement : String, code : String) : Bool
        if match = code.match(CREATE_TABLE)
          @created << Linter.identifier(match[1])
        elsif match = code.match(CREATE_INDEX)
          create_index(statement, match)
        elsif match = code.match(DROP_INDEX)
          drop_index(statement, match)
        elsif match = code.match(DROP_TABLE)
          drop_table(statement, Linter.identifier(match[1]))
        elsif match = code.match(TRUNCATE)
          truncate(statement, Linter.identifier(match[1]))
        elsif match = code.match(UPDATE) || code.match(DELETE)
          bulk_write(statement, code, Linter.identifier(match[1]))
        elsif match = code.match(DO_BLOCK)
          hidden(statement, match[2])
        elsif match = code.match(ALTER_TABLE)
          alter_table(statement, Linter.identifier(match[1]), Linter.split(match[2], ','))
        else
          return false
        end
        true
      end

      private def alter_table(statement : String, table : String, actions : Array(String)) : Nil
        actions.each do |action|
          if match = action.match(RENAME_TABLE)
            rename_table(statement, table, Linter.identifier(match[1]))
          elsif match = action.match(ADD_COLUMN)
            add_column(statement, table, action, Linter.identifier(match[1]))
          elsif match = action.match(DROP_COLUMN)
            drop_column(statement, table, Linter.identifier(match[1]))
          elsif match = action.match(RENAME_COLUMN)
            rename_column(statement, table, Linter.identifier(match[1]))
          elsif match = action.match(ALTER_TYPE)
            alter_type(statement, table, Linter.identifier(match[1]))
          elsif match = action.match(SET_NOT_NULL)
            set_not_null(statement, table, Linter.identifier(match[1]))
          elsif match = action.match(ADD_CONSTRAINT)
            add_constraint(statement, table, action, match)
          end
        end
      end

      private def existing?(relation : String) : Bool
        !@created.includes?(relation)
      end

      private def refuse(rule : String,
                         subject : String,
                         statement : String,
                         message : String,
                         remediation : String) : Nil
        return if @allowed.includes?({rule, subject})
        @violations << Violation.new(
          rule: rule,
          message: message,
          remediation: remediation,
          migration: @label,
          statement: statement,
          file: @migration.file,
        )
      end

      private def create_index(statement : String, match : Regex::MatchData) : Nil
        match[2]?.try { |name| @created << Linter.identifier(name) }
        table = Linter.identifier(match[3])
        return if match[1]? || !existing?(table)
        refuse("concurrent-index", table, statement,
          "CREATE INDEX on existing table #{table} blocks its writes while the index builds.",
          "use CREATE INDEX CONCURRENTLY in a migration of its own; frappe db diff emits it " \
          "that way. A partitioned table, which cannot be indexed CONCURRENTLY, needs the line " \
          "-- caramel:allow concurrent-index #{table}")
      end

      private def drop_index(statement : String, match : Regex::MatchData) : Nil
        name = Linter.identifier(match[2])
        return if match[1]? || !existing?(name)
        refuse("concurrent-drop-index", name, statement,
          "DROP INDEX #{name} locks its table against reads and writes " \
          "while it waits for running queries.",
          "use DROP INDEX CONCURRENTLY in a migration of its own; frappe db diff emits it " \
          "that way. Hand-written SQL that must drop it in a transaction needs the line " \
          "-- caramel:allow concurrent-drop-index #{name}")
      end

      private def drop_table(statement : String, table : String) : Nil
        return unless existing?(table)
        refuse("drop-table", table, statement,
          "DROP TABLE #{table} destroys the table and every row in it.",
          "remove the statement, or state the intent with the line " \
          "-- caramel:allow drop-table #{table}")
      end

      private def truncate(statement : String, table : String) : Nil
        return unless existing?(table)
        refuse("truncate", table, statement,
          "TRUNCATE #{table} deletes every row and locks the table against reads and writes.",
          "delete the rows in batches from a job, or state the intent with the line " \
          "-- caramel:allow truncate #{table}")
      end

      private def bulk_write(statement : String, code : String, table : String) : Nil
        return unless existing?(table)
        verb = code.starts_with?(/UPDATE/i) ? "UPDATE" : "DELETE FROM"
        refuse("bulk-write", table, statement,
          "#{verb} #{table} rewrites its matching rows in the migration's transaction " \
          "and holds their locks until it commits.",
          "backfill in batches from a job or a script outside the migration, or state the " \
          "intent with the line -- caramel:allow bulk-write #{table}")
      end

      private def rename_table(statement : String, table : String, to : String) : Nil
        return unless existing?(table)
        refuse("rename-table", table, statement,
          "ALTER TABLE #{table} RENAME TO #{to} breaks the binary still serving #{table}.",
          "keep #{table} until no running binary reads it, or state the intent with the line " \
          "-- caramel:allow rename-table #{table}")
      end

      private def add_column(statement : String,
                             table : String,
                             action : String,
                             column : String) : Nil
        return unless existing?(table) && action.matches?(NOT_NULL)
        return if action.matches?(DEFAULTED)
        refuse("not-null-default", "#{table}.#{column}", statement,
          "ADD COLUMN #{column} NOT NULL without a DEFAULT fails on a populated #{table} table.",
          "give the column a DEFAULT, or add it nullable, backfill it, and tighten it later.")
      end

      private def drop_column(statement : String, table : String, column : String) : Nil
        refuse("destructive-column", "#{table}.#{column}", statement,
          "DROP COLUMN #{column} destroys the data in #{table}.#{column}.",
          "declare drop_column :#{column} in the schema and diff again; hand-written SQL " \
          "needs the line -- caramel:allow-drop #{table}.#{column}")
      end

      private def rename_column(statement : String, table : String, column : String) : Nil
        refuse("destructive-column", "#{table}.#{column}", statement,
          "RENAME COLUMN #{column} breaks code that still reads #{table}.#{column}.",
          "declare renamed_from: :#{column} on the new field and diff again; hand-written " \
          "SQL needs the line -- caramel:allow-rename #{table}.#{column}")
      end

      private def alter_type(statement : String, table : String, column : String) : Nil
        return unless existing?(table)
        refuse("alter-column-type", "#{table}.#{column}", statement,
          "ALTER COLUMN #{column} TYPE rewrites #{table} under a lock " \
          "that blocks its reads and writes.",
          "add a column of the new type, backfill it in batches and switch to it; " \
          "a retype whose values the migration checks first needs the line " \
          "-- caramel:allow alter-column-type #{table}.#{column}")
      end

      private def set_not_null(statement : String, table : String, column : String) : Nil
        return unless existing?(table)
        refuse("set-not-null", "#{table}.#{column}", statement,
          "ALTER COLUMN #{column} SET NOT NULL scans every row of #{table} under a lock " \
          "that blocks its reads and writes.",
          "add CONSTRAINT … CHECK (#{column} IS NOT NULL) NOT VALID, VALIDATE CONSTRAINT it " \
          "in a migration of its own, then SET NOT NULL, which no longer scans; or state " \
          "the intent with the line -- caramel:allow set-not-null #{table}.#{column}")
      end

      # CHECK and FOREIGN KEY scan the rows unless added NOT VALID; UNIQUE and
      # PRIMARY KEY build an index unless they adopt one built CONCURRENTLY.
      private def add_constraint(statement : String,
                                 table : String,
                                 action : String,
                                 match : Regex::MatchData) : Nil
        return unless existing?(table)
        kind = match[2].upcase.gsub(/\s+/, " ")
        name = match[1]?.try { |token| Linter.identifier(token) }
        label = name ? "CONSTRAINT #{name} #{kind}" : "a #{kind} constraint"
        allow = "or state the intent with the line -- caramel:allow constraint-not-valid #{table}"
        if kind.in?("CHECK", "FOREIGN KEY")
          return if action.matches?(NOT_VALID)
          refuse("constraint-not-valid", table, statement,
            "ADD #{label} scans every row of #{table} under a lock that blocks its writes.",
            "add it NOT VALID, then VALIDATE CONSTRAINT in a migration of its own; " \
            "frappe db diff emits it that way; #{allow}")
        else
          return if action.matches?(USING_INDEX)
          refuse("constraint-not-valid", table, statement,
            "ADD #{label} builds its index while #{table} is locked against writes.",
            "build the unique index CONCURRENTLY in a migration of its own, then " \
            "ADD CONSTRAINT … #{kind} USING INDEX; #{allow}")
        end
      end

      # The statements of a DO block, each checked as if it stood alone and reported
      # under hidden-ddl; the annotation of the hidden rule exempts it. A statement
      # may start at the body's beginning or after a control keyword.
      private def hidden(statement : String, body : String) : Nil
        before = @violations.size
        Linter.split(body, ';').each do |chunk|
          starts = [0] + chunk.scan(CONTROL).map(&.end(0))
          starts.each { |start| break if scan(statement, Linter.code(chunk[start..])) }
        end
        (before...@violations.size).each do |index|
          inner = @violations[index]
          @violations[index] = inner.copy_with(
            rule: "hidden-ddl",
            message: "DO block hides #{inner.rule}: #{inner.message}",
            remediation: "write the statement outside the DO block; #{inner.remediation}",
          )
        end
      end

      private def mixed_concurrency : Nil
        statements = @migration.statements
        concurrent = statements.find { |statement| Linter.concurrent?(statement) } || return
        return if statements.all? { |statement| Linter.online?(statement) }
        @violations << Violation.new(
          rule: "mixed-concurrency",
          message: "CONCURRENTLY statements cannot run inside the transaction " \
                   "this migration's other statements need.",
          remediation: "move the CONCURRENTLY statements into a migration " \
                       "of their own; frappe db diff splits them for you.",
          migration: @label,
          statement: concurrent,
          file: @migration.file,
        )
      end
    end
  end
end
