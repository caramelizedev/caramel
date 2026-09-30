require "db"
require "../database"
require "../../sugar_orm"

module Corretto
  class Error < Exception
  end

  # Tier 2 and Tier 3 isolation for one spec process and its worker database.
  #
  # Every example runs on the worker's single runtime connection inside
  # BEGIN + SAVEPOINT, bound to the example's fiber with `SugarORM::Repo.bind`,
  # and is rolled back afterwards. The catalog fingerprint taken at boot is
  # compared after each example; a difference means DDL escaped the
  # transaction, so the worker database is reset from the migrated template.
  # `catalog` examples run unwrapped on a migration-role connection, so they
  # may run DDL, and always reset afterwards.
  class Worker
    OUTSIDE_EXAMPLE = "Corretto.session runs inside an example (`it`), " \
                      "whose connection Corretto binds and rolls back."

    # What the fingerprint records of a column besides its table and name.
    COLUMN_DETAILS = "format_type(a.atttypid, a.atttypmod), a.attnotnull::text, " \
                     "a.attisdropped::text, a.attidentity::text, " \
                     "pg_get_expr(d.adbin, d.adrelid)"

    # Escapes are interpreted: PostgreSQL receives `E'\\n'` as E'\n', and a
    # trailing backslash joins a long line to the next.
    FINGERPRINT_SQL = <<-SQL
      SELECT md5(coalesce(string_agg(entry, E'\\n' ORDER BY entry), '')) FROM (
        SELECT concat_ws(' ', 'class', c.relname, c.relkind::text, c.relpersistence::text) AS entry
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'
        UNION ALL
        SELECT concat_ws(' ', 'attribute', c.relname, a.attname, #{COLUMN_DETAILS})
          FROM pg_attribute a
          JOIN pg_class c ON c.oid = a.attrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
          WHERE n.nspname = 'public' AND a.attnum > 0
        UNION ALL
        SELECT concat_ws(' ', 'index', pg_get_indexdef(i.indexrelid))
          FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid \
            JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'public'
        UNION ALL
        SELECT concat_ws(' ', 'constraint', con.conname, c.relname, pg_get_constraintdef(con.oid))
          FROM pg_constraint con JOIN pg_namespace n ON n.oid = con.connamespace \
            LEFT JOIN pg_class c ON c.oid = con.conrelid
          WHERE n.nspname = 'public'
      ) catalog
      SQL

    getter database : DB::Database
    getter fingerprint : String
    getter resets = 0
    @connection : DB::Connection? = nil
    @migration : DB::Database? = nil

    # `reset` must recreate the database behind `runtime_url` from the migrated
    # template; every connection to it is closed first.
    def initialize(@runtime_url : String, @migration_url : String, @reset : Proc(Nil))
      @database = Caramel::Database.open(@runtime_url, 1)
      @fingerprint = current_fingerprint
    end

    # The running example's connection; `Corretto.session` yields it.
    def connection : DB::Connection
      @connection || raise Error.new(OUTSIDE_EXAMPLE)
    end

    # Runs one example isolated. Returns true when the example changed the
    # catalog outside its transaction and the database was reset.
    def run(catalog : Bool = false, &) : Bool
      if catalog
        begin
          migration.using_connection do |connection|
            within(connection) { SugarORM::Repo.bind(connection) { yield } }
          end
        ensure
          reset!
        end
        return false
      end
      @database.using_connection do |connection|
        connection.transaction do |transaction|
          transaction.transaction do |savepoint|
            within(connection) { SugarORM::Repo.bind(savepoint) { yield } }
            savepoint.rollback
          end
          transaction.rollback
        end
      end
      return false if current_fingerprint == @fingerprint
      reset!
      true
    end

    def current_fingerprint : String
      @database.query_one(FINGERPRINT_SQL, as: String)
    end

    def close : Nil
      @migration.try(&.close)
      @database.close
    end

    private def migration : DB::Database
      @migration ||= Caramel::Database.open(@migration_url, 1)
    end

    private def within(connection : DB::Connection, &) : Nil
      @connection = connection
      yield
    ensure
      @connection = nil
    end

    private def reset! : Nil
      close
      @migration = nil
      @reset.call
      @database = Caramel::Database.open(@runtime_url, 1)
      @resets += 1
    end
  end
end
