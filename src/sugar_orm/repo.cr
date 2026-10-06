require "db"
require "pg"

class Fiber
  # The connection (and transaction) SugarORM uses for work in this fiber;
  # set only by SugarORM::Repo.bind and SugarORM::Repo.transaction.
  property __sugar_connection : ::DB::Connection? = nil
  property __sugar_transaction : ::DB::Transaction? = nil
end

module SugarORM
  # Every bind value SugarORM sends: crystal-db scalars plus the arrays used by
  # `= ANY($n)`.
  alias Value = ::DB::Any | Array(String) | Array(Int32) | Array(Int64) |
                Array(Float64) | Array(Bool) | Array(Time)

  # An explicit database handle for the `(db, ...)` overloads.
  alias Handle = ::DB::Database | ::DB::Connection

  class Error < Exception
  end

  class ConfigurationError < Error
  end

  class NotFound < Error
  end

  class ShapeError < Error
  end

  # PostgreSQL SQLSTATE 23505 raised by any Repo statement.
  class UniqueViolation < Error
    getter table : String?
    getter constraint : String?
    getter columns : Array(String)

    def initialize(message : String?,
                   @table : String?,
                   @constraint : String?,
                   @columns : Array(String),
                   cause : Exception? = nil)
      super(message, cause)
    end

    def self.from(error : PQ::PQError) : self
      detail = error.field_message(:detail) || ""
      columns = detail.match(/\AKey \(([^)]*)\)=/).try(&.[1].split(", ")) || [] of String
      table = error.field_message(:table_name)
      constraint = error.field_message(:constraint_name)
      new(error.message, table, constraint, columns, error)
    end

    # True when the violated index or constraint leads with `column` of `table`.
    def on?(table : String, column : String) : Bool
      return false unless @table.nil? || @table == table
      return true if @columns.first? == column
      @constraint.in?("index_#{table}_on_#{column}", "#{table}_#{column}_key")
    end
  end

  # Unset keyword arguments in generated signatures.
  struct Unset
  end

  UNSET = Unset.new

  module Repo
    @@database : ::DB::Database? = nil
    @@statements_executed = 0_i64

    def self.database=(database : ::DB::Database) : ::DB::Database
      @@database = database
    end

    def self.database : ::DB::Database
      @@database || raise ConfigurationError.new(
        "SugarORM::Repo.database is not configured.\n" \
        "Remediation: set `SugarORM::Repo.database = Caramel::Database.open(url)` " \
        "once during boot."
      )
    end

    # Statements SugarORM has sent in this process. Specs compare deltas to
    # prove query counts; BEGIN, COMMIT and SAVEPOINT are not counted.
    def self.statements_executed : Int64
      @@statements_executed
    end

    # Runs the block with `connection` bound to the current fiber: all SugarORM
    # work in the block, and `Repo.connection`, uses it.
    def self.bind(connection : ::DB::Connection, &)
      transaction = Fiber.current.__sugar_transaction
      transaction = nil unless transaction && transaction.connection.same?(connection)
      within(connection, transaction) { yield }
    end

    # Like `bind(connection)` for a transaction opened elsewhere: nested
    # `Repo.transaction` calls become savepoints inside it.
    def self.bind(transaction : ::DB::Transaction, &)
      within(transaction.connection, transaction) { yield }
    end

    # Runs the block against an explicit handle (the `(db, ...)` overloads).
    # One `yield`, so each caller's block is compiled once.
    def self.using(db : Handle, &)
      connection = db.is_a?(::DB::Connection) ? db : db.checkout
      begin
        bind(connection) { yield }
      ensure
        connection.release unless db.is_a?(::DB::Connection)
      end
    end

    # The only supported way to reach the current (bound or transaction)
    # connection. Unbound work checks a connection out of the pool and returns
    # it afterwards, as `DB::Database#using_connection` does, with one `yield`.
    def self.connection(& : ::DB::Connection -> R) : R forall R
      bound = Fiber.current.__sugar_connection
      connection = bound || observe_checkout { database.checkout }
      begin
        yield connection
      ensure
        connection.release unless bound
      end
    end

    # Runs the block in a transaction; a nested call opens a savepoint. Raising
    # rolls back and re-raises, except `Repo.rollback`, which returns nil.
    def self.transaction(&)
      if current = Fiber.current.__sugar_transaction
        current.transaction { |nested| within(nested.connection, nested) { yield } }
      else
        connection do |connection|
          connection.transaction do |transaction|
            within(connection, transaction) { yield }
          end
        end
      end
    end

    def self.rollback : NoReturn
      raise ::DB::Rollback.new
    end

    def self.in_transaction? : Bool
      !Fiber.current.__sugar_transaction.nil?
    end

    def self.exec(sql : String, args : Array(Value) = [] of Value) : ::DB::ExecResult
      connection do |connection|
        observe(sql, args) { |tagged| statement { connection.exec(tagged, args: args) } }
      end
    end

    # Yields the open result set, positioned before the first row.
    def self.query(sql : String,
                   args : Array(Value),
                   & : ::DB::ResultSet -> R) : R forall R
      connection do |connection|
        observe(sql, args) do |tagged|
          statement { connection.query(tagged, args: args) { |rows| yield rows } }
        end
      end
    end

    def self.query_all(sql : String,
                       args : Array(Value),
                       & : ::DB::ResultSet -> R) : Array(R) forall R
      query(sql, args) do |rows|
        results = [] of R
        rows.each { results << yield rows }
        results
      end
    end

    def self.query_one?(sql : String,
                        args : Array(Value),
                        & : ::DB::ResultSet -> R) : R? forall R
      query(sql, args) do |rows|
        rows.move_next ? yield rows : nil
      end
    end

    def self.insert(changeset : Changeset)
      changeset.__sugar_insert
      changeset
    end

    def self.update(changeset : Changeset)
      changeset.__sugar_update
      changeset
    end

    # Deletes the changeset's record; a missing row becomes a `_base` error.
    def self.delete(changeset : Changeset)
      changeset.__sugar_delete
      changeset
    end

    def self.delete(record : Schema) : Bool
      schema = record.class
      args = [record.__sugar_primary_value] of Value
      sql = "DELETE FROM #{schema.__sugar_quoted_table} " \
            "WHERE \"#{schema.__sugar_primary_key}\" = $1#{SugarORM.tenant_filter(schema, args)}"
      exec(sql, args).rows_affected == 1
    end

    {% for name in %w[insert update delete] %}
      def self.{{ name.id }}(db : Handle, target)
        using(db) { {{ name.id }}(target) }
      end
    {% end %}

    # Runs one statement. `caramel/crema` replaces it to time the statement and
    # to hand the block SQL that carries a leading comment naming the code that
    # ran it. SugarORM alone yields *sql* as written.
    private def self.observe(sql : String, args : Array(Value), & : String -> R) : R forall R
      yield sql
    end

    # Checks a connection out of the pool. `caramel/crema` replaces it to time
    # the wait.
    private def self.observe_checkout(& : -> ::DB::Connection) : ::DB::Connection
      yield
    end

    private def self.statement(&)
      @@statements_executed += 1
      yield
    rescue error : PQ::PQError
      raise error.field_message(:code) == "23505" ? UniqueViolation.from(error) : error
    end

    private def self.within(connection : ::DB::Connection,
                            transaction : ::DB::Transaction?,
                            &)
      fiber = Fiber.current
      previous_connection = fiber.__sugar_connection
      previous_transaction = fiber.__sugar_transaction
      fiber.__sugar_connection = connection
      fiber.__sugar_transaction = transaction
      begin
        yield
      ensure
        fiber.__sugar_connection = previous_connection
        fiber.__sugar_transaction = previous_transaction
      end
    end
  end
end
