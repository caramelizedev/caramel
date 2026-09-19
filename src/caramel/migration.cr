require "db"
require "digest/sha256"

module Caramel
  # Migrations are compiled application code; SQL is never derived from a request.
  struct Migration
    getter version : Int64
    getter name : String
    getter statements : Array(String)

    def initialize(@version, @name, @statements)
      raise ArgumentError.new("migration version must be positive") unless @version > 0
      raise ArgumentError.new("migration needs a name and SQL") if @name.strip.empty? || @statements.empty? || @statements.any?(&.strip.empty?)
    end

    def checksum : String
      Digest::SHA256.hexdigest(([name] + statements).map { |s| "#{s.bytesize}:#{s}" }.join)
    end
  end

  class Migrator
    class Drift < Exception; end

    LOCK_ID = 0x434152414D454C_i64
    @migrations : Array(Migration)

    def initialize(@db : DB::Database, migrations : Array(Migration))
      @migrations = migrations.sort_by(&.version)
      if @migrations.map(&.version).uniq.size != @migrations.size
        raise ArgumentError.new("duplicate migration versions")
      end
    end

    # Read-only: checking pending migrations must never create schema objects.
    def pending : Array(Migration)
      @db.using_connection { |connection| pending(connection) }
    end

    # One transaction and transaction-scoped advisory lock cover the batch.
    # Failed SQL rolls back both application DDL and the migration journal.
    def migrate : Int32
      count = 0
      @db.transaction do |transaction|
        connection = transaction.connection
        connection.exec("SELECT pg_advisory_xact_lock($1)", LOCK_ID)
        connection.exec(<<-SQL)
          CREATE TABLE IF NOT EXISTS caramel_migrations (
            version bigint PRIMARY KEY,
            name text NOT NULL,
            checksum text NOT NULL,
            applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
          )
          SQL
        pending(connection).each do |migration|
          migration.statements.each { |sql| connection.exec(sql) }
          connection.exec("INSERT INTO caramel_migrations (version, name, checksum) VALUES ($1, $2, $3)", migration.version, migration.name, migration.checksum)
          count += 1
        end
      end
      count
    end

    private def pending(connection : DB::Connection) : Array(Migration)
      return @migrations.dup unless connection.query_one("SELECT to_regclass('caramel_migrations')::text", as: String?)
      applied = {} of Int64 => String
      connection.query("SELECT version, checksum FROM caramel_migrations") do |rows|
        rows.each { applied[rows.read(Int64)] = rows.read(String) }
      end
      applied.each do |version, checksum|
        migration = @migrations.find { |candidate| candidate.version == version }
        raise Drift.new("Applied migration #{version} is missing from this application") unless migration
        raise Drift.new("Applied migration #{version} has changed; create a new migration") unless migration.checksum == checksum
      end
      @migrations.reject { |migration| applied.has_key?(migration.version) }
    end
  end
end
