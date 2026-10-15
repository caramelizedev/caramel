require "db"
require "pg"
require "digest/sha256"
require "./linter"
require "./ddl"

module SugarORM
  # Migrations are compiled application code; SQL is never derived from a request.
  struct Migration
    getter version : Int64
    getter name : String
    getter statements : Array(String)
    # The source file that declared the migration, for diagnostics.
    getter file : String

    # A default of `__FILE__` expands where the caller wrote `Migration.new`
    # only on an explicit class method, not on `initialize`.
    def self.new(version : Int64,
                 name : String,
                 statements : Array(String),
                 file : String = __FILE__) : self
      new(version, name, statements, declared_in: file)
    end

    private def initialize(@version, @name, @statements, *, declared_in : String)
      @file = declared_in
      raise ArgumentError.new("migration version must be positive") unless @version > 0
      raise ArgumentError.new("migration needs a name and SQL") if incomplete?
    end

    def checksum : String
      parts = [name] + statements
      framed = parts.map { |part| "#{part.bytesize}:#{part}" }
      Digest::SHA256.hexdigest(framed.join)
    end

    # A migration made only of online statements (CONCURRENTLY index builds
    # and drops, constraint validation) runs outside a transaction.
    def transactional? : Bool
      !@statements.all? { |statement| Linter.online?(statement) }
    end

    def to_s(io : IO) : Nil
      io << "migration " << @version << " (" << @name << ')'
    end

    private def incomplete? : Bool
      return true if @name.strip.empty?
      @statements.empty? || @statements.any?(&.strip.empty?)
    end
  end

  class Migrator
    class Drift < Exception; end

    class ConcurrentIndexFailed < Exception
      getter index : String

      def initialize(migration : Migration, @index : String, cause : Exception?)
        reason = cause.try(&.message) || "PostgreSQL marked the index INVALID"
        super(<<-TEXT, cause)
          #{migration} failed while building index #{@index} CONCURRENTLY: #{reason}
          PostgreSQL left #{@index} INVALID: queries ignore it, yet every write still maintains it.
            Remediation: run DROP INDEX CONCURRENTLY #{DDL.quote(@index)}; fix the cause \
              (for a unique index, remove the duplicate rows), then migrate again.
          TEXT
      end
    end

    # A VALIDATE CONSTRAINT that existing rows fail. The constraint stays
    # NOT VALID: it refuses new rows that break it.
    class ValidationFailed < Exception
      getter constraint : String

      def initialize(migration : Migration,
                     table : String,
                     @constraint : String,
                     cause : PQ::PQError)
        super(<<-TEXT, cause)
          #{migration} failed while validating #{@constraint} on #{table}: #{cause.message}
          #{@constraint} stays NOT VALID: it refuses new rows that break it, \
          but rows written before it still do.
            Remediation: fix or delete those rows, then migrate again.
          TEXT
      end
    end

    # A transactional migration that still hit lock_timeout after every retry.
    # It rolled back and is not journaled.
    class LockTimedOut < Exception
      def initialize(migration : Migration, attempts : Int32, cause : PQ::PQError)
        super(<<-TEXT, cause)
          #{migration} timed out waiting for a lock #{attempts} times: #{cause.message}
          It rolled back and is not journaled, so the next migrate runs it again.
            Remediation: find the session holding a lock on its tables \
              (pg_locks joined to pg_stat_activity), let it finish or end it, then \
              migrate again; CARAMEL_MIGRATION_LOCK_TIMEOUT sets how long each wait lasts.
          TEXT
      end
    end

    # What `frappe migrate` reports and exits 1 for.
    alias Failure = Drift | ConcurrentIndexFailed | ValidationFailed | LockTimedOut

    LOCK_ID            = 0x434152414D454C_i64
    LOCK_NOT_AVAILABLE = "55P03"
    LOCK_RETRY_DELAYS  = [1.second, 2.seconds, 4.seconds]
    @migrations : Array(Migration)

    def initialize(@db : DB::Database,
                   migrations : Array(Migration),
                   @warnings : IO = STDERR,
                   @lock_retry_delays : Array(Time::Span) = LOCK_RETRY_DELAYS)
      @migrations = migrations.sort_by(&.version)
      if @migrations.map(&.version).uniq!.size != @migrations.size
        raise ArgumentError.new("duplicate migration versions")
      end
    end

    # Read-only: checking pending migrations must never create schema objects.
    def pending : Array(Migration)
      @db.using_connection { |connection| pending(connection) }
    end

    def lint : Array(Linter::Violation)
      Linter.lint(pending)
    end

    # One session-level advisory lock covers the run. Pending migrations are
    # linted before any statement executes. Each transactional migration runs in
    # a transaction of its own that also writes its journal row, so a failure
    # keeps the migrations before it. An online migration runs each statement in
    # autocommit and is journaled last.
    def migrate(dev_override : Bool = false,
                environment : String = Linter.environment) : Int32
      @db.using_connection do |connection|
        connection.exec("SELECT pg_advisory_lock($1)", LOCK_ID)
        begin
          pending = pending(connection)
          Linter.enforce(Linter.lint(pending), dev_override, environment, @warnings)
          connection.exec(<<-SQL)
            CREATE TABLE IF NOT EXISTS caramel_migrations (
              version bigint PRIMARY KEY,
              name text NOT NULL,
              checksum text NOT NULL,
              applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            SQL
          pending.each do |migration|
            if migration.transactional?
              run_transactional(connection, migration)
            else
              run_online(connection, migration)
            end
          end
          pending.size
        ensure
          connection.exec("SELECT pg_advisory_unlock($1)", LOCK_ID)
        end
      end
    end

    # A lock timeout rolls the migration back; it runs again after each of
    # @lock_retry_delays, then LockTimedOut.
    private def run_transactional(connection : DB::Connection, migration : Migration) : Nil
      @lock_retry_delays.each_with_index do |delay, index|
        return apply(connection, migration)
      rescue error : PQ::PQError
        raise error unless error.field_message(:code) == LOCK_NOT_AVAILABLE
        @warnings.puts "#{migration} timed out waiting for a lock; " \
                       "retry #{index + 1} of #{@lock_retry_delays.size} " \
                       "in #{delay.total_milliseconds.to_i} ms"
        sleep delay
      end
      begin
        apply(connection, migration)
      rescue error : PQ::PQError
        raise error unless error.field_message(:code) == LOCK_NOT_AVAILABLE
        raise LockTimedOut.new(migration, @lock_retry_delays.size + 1, error)
      end
    end

    private def apply(connection : DB::Connection, migration : Migration) : Nil
      connection.transaction do
        migration.statements.each { |sql| connection.exec(sql) }
        journal(connection, migration)
      end
      nil
    end

    # Online statements take SHARE UPDATE EXCLUSIVE, which no read or write waits
    # behind, and CONCURRENTLY waits for older transactions, so they run with no
    # lock_timeout.
    private def run_online(connection : DB::Connection, migration : Migration) : Nil
      saved = connection.query_one("SELECT current_setting('lock_timeout')", as: String)
      connection.exec("SELECT set_config('lock_timeout', '0', false)")
      begin
        migration.statements.each do |sql|
          index = Linter.concurrent_index(sql)
          begin
            connection.exec(sql)
          rescue ex : PQ::PQError
            if index && invalid_index?(connection, index)
              raise ConcurrentIndexFailed.new(migration, index, ex)
            end
            Linter.validated_constraint(sql).try do |table, constraint|
              raise ValidationFailed.new(migration, table, constraint, ex)
            end
            raise ex
          end
          # IF NOT EXISTS skips an INVALID leftover silently; refuse to journal it.
          if index && invalid_index?(connection, index)
            raise ConcurrentIndexFailed.new(migration, index, nil)
          end
        end
        journal(connection, migration)
      ensure
        connection.exec("SELECT set_config('lock_timeout', $1, false)", saved)
      end
    end

    private def invalid_index?(connection : DB::Connection, index : String) : Bool
      connection.query_one?(<<-SQL, index, as: Bool) || false
        SELECT NOT x.indisvalid
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_namespace n ON n.oid = i.relnamespace
        WHERE i.relname = $1 AND n.nspname = current_schema()
        SQL
    end

    private def journal(connection : DB::Connection, migration : Migration) : Nil
      sql = "INSERT INTO caramel_migrations (version, name, checksum) VALUES ($1, $2, $3)"
      connection.exec(sql, migration.version, migration.name, migration.checksum)
    end

    private def pending(connection : DB::Connection) : Array(Migration)
      regclass = "SELECT to_regclass('caramel_migrations')::text"
      return @migrations.dup unless connection.query_one(regclass, as: String?)
      applied = {} of Int64 => String
      connection.query("SELECT version, checksum FROM caramel_migrations") do |rows|
        rows.each { applied[rows.read(Int64)] = rows.read(String) }
      end
      applied.each do |version, checksum|
        subject = "Applied migration #{version}"
        migration = @migrations.find { |candidate| candidate.version == version }
        raise Drift.new("#{subject} is missing from this application") unless migration
        changed = migration.checksum != checksum
        raise Drift.new("#{subject} has changed; create a new migration") if changed
      end
      @migrations.reject { |migration| applied.has_key?(migration.version) }
    end
  end
end
