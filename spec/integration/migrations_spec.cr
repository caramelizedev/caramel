require "spec"
require "random/secure"
require "../../src/caramel/database"
require "../../src/sugar_orm/migration"
require "../../src/sugar_orm/differ"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
MIGRATIONS_ADMIN_URL = ENV["CARAMEL_OWNED_ADMIN_URL"]? || raise "Run scripts/check integration; no owned admin connection provided"
MIGRATIONS_OWNER_URL = ENV["CARAMEL_OWNED_SPEC_URL"]? || raise "Run scripts/check integration; no owned test database provided"

# Every example migrates a fresh database owned by the non-superuser spec role,
# so journals and tables never leak between examples.
private def with_scratch_database(&)
  name = "caramel_migrations_#{Random::Secure.hex(6)}"
  admin = Caramel::Database.open(MIGRATIONS_ADMIN_URL, 1)
  begin
    admin.exec(%(CREATE DATABASE "#{name}" OWNER caramel_spec))
    db = Caramel::Database.open(MIGRATIONS_OWNER_URL.sub("/caramel_spec?", "/#{name}?"), 2)
    begin
      yield db
    ensure
      db.close
    end
  ensure
    admin.exec(%(DROP DATABASE IF EXISTS "#{name}" WITH (FORCE)))
    admin.close
  end
end

private def migration(version : Int, name : String, *statements : String) : SugarORM::Migration
  SugarORM::Migration.new(version.to_i64, name, statements.to_a)
end

private def journal(db : DB::Database) : Array(Int64)
  db.query_all("SELECT version FROM caramel_migrations ORDER BY version", as: Int64)
end

private alias Catalog = SugarORM::Catalog

describe SugarORM::Migrator do
  it "reads back every declared catalog value after its DDL runs" do
    id = Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true)
    declared = [
      Catalog::Table.new("authors", [id, Catalog::Column.new("name", "text", false, "'it''s anonymous'")]),
      Catalog::Table.new("books", [
        id,
        Catalog::Column.new("title", "text", false, nil),
        Catalog::Column.new("seats", "integer", false, "5"),
        Catalog::Column.new("balance", "bigint", false, "-3"),
        Catalog::Column.new("archived", "boolean", false, "false"),
        Catalog::Column.new("rating", "double precision", true, "2.5"),
        Catalog::Column.new("subtitle", "text", true, nil),
        Catalog::Column.new("author_id", "bigint", true, nil),
        Catalog::Column.new("created_at", "timestamp with time zone", false, "CURRENT_TIMESTAMP"),
        Catalog::Column.new("updated_at", "timestamp with time zone", false, "CURRENT_TIMESTAMP"),
      ], [
        Catalog::Index.new("index_books_on_author_id", ["author_id"]),
        Catalog::Index.new("index_books_on_title_and_seats", ["title", "seats"], unique: true),
      ], [Catalog::ForeignKey.new("fk_books_author_id", "author_id", "authors", on_delete: "CASCADE")]),
    ]
    with_scratch_database do |db|
      statements = SugarORM::DDL.statements(SugarORM::Differ.diff(declared, [] of Catalog::Table).transactional)
      SugarORM::Migrator.new(db, [SugarORM::Migration.new(1_i64, "create", statements)]).migrate.should eq(1)
      snapshot = SugarORM::Introspection.read(db)
      snapshot.tables.reject(&.name.starts_with?("caramel_")).should eq(declared)
      snapshot.invalid_indexes.should be_empty
      plan = SugarORM::Differ.diff(declared, snapshot)
      plan.clean?.should be_true
      plan.notes.should eq(["ignored table caramel_migrations (owned by Caramel)"])
    end
  end

  it "applies transactional migrations once, rolls back a failed batch and detects checksum drift" do
    with_scratch_database do |db|
      create = migration(1, "Create books", "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, title text NOT NULL)")
      runner = SugarORM::Migrator.new(db, [create])
      runner.pending.map(&.version).should eq([1_i64])
      db.query_one("SELECT to_regclass('caramel_migrations')::text", as: String?).should be_nil
      runner.migrate.should eq(1)
      runner.migrate.should eq(0)
      db.exec("INSERT INTO books (title) VALUES ($1)", "A book")

      broken = migration(2, "Broken", "CREATE TABLE rollback_probe (id int)", "INSERT INTO absent_table VALUES (1)")
      expect_raises(PQ::PQError) { SugarORM::Migrator.new(db, [create, broken]).migrate }
      db.query_one("SELECT to_regclass('rollback_probe')::text", as: String?).should be_nil
      journal(db).should eq([1_i64])

      changed = migration(1, "Create books", "CREATE TABLE changed (id int)")
      expect_raises(SugarORM::Migrator::Drift, "has changed") { SugarORM::Migrator.new(db, [changed]).pending }
      expect_raises(SugarORM::Migrator::Drift, "is missing") { SugarORM::Migrator.new(db, [] of SugarORM::Migration).migrate }
    end
  end

  it "accepts a journal written by the previous Caramel migrator" do
    with_scratch_database do |db|
      db.exec("CREATE TABLE caramel_migrations (version bigint PRIMARY KEY, name text NOT NULL, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP)")
      db.exec("INSERT INTO caramel_migrations (version, name, checksum) VALUES (1, 'Create books', '7435dfea99988971c39b6dad7ccbead9e1b6361da715b80c41688e04ae344bcb')")
      create = migration(1, "Create books", "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, title text NOT NULL)")
      SugarORM::Migrator.new(db, [create]).pending.should be_empty
    end
  end

  it "runs an all-CONCURRENTLY migration outside a transaction between committed batches" do
    with_scratch_database do |db|
      migrations = [
        migration(1, "create_books", "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, isbn text NOT NULL)",
          "INSERT INTO books (isbn) SELECT 'isbn-' || n FROM generate_series(1, 500) AS n"),
        migration(2, "index_isbn", %(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "index_books_on_isbn" ON "books" ("isbn"))),
        migration(3, "add_pages", %(ALTER TABLE "books" ADD COLUMN "pages" integer NOT NULL DEFAULT 0)),
      ]
      migrations.map(&.transactional?).should eq([true, false, true])
      SugarORM::Migrator.new(db, migrations).migrate.should eq(3)
      db.query_one("SELECT indisvalid AND indisunique FROM pg_index WHERE indexrelid = 'index_books_on_isbn'::regclass", as: Bool).should be_true
      journal(db).should eq([1_i64, 2_i64, 3_i64])
      db.query_one("SELECT count(*) FROM books WHERE pages = 0", as: Int64).should eq(500_i64)
    end
  end

  it "names the INVALID index a failed concurrent build leaves and refuses to journal it" do
    with_scratch_database do |db|
      create = migration(1, "create_books", "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, isbn text NOT NULL)",
        "INSERT INTO books (isbn) VALUES ('same'), ('same')")
      index = migration(2, "index_isbn", %(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "index_books_on_isbn" ON "books" ("isbn")))
      runner = SugarORM::Migrator.new(db, [create, index])
      failure = expect_raises(SugarORM::Migrator::ConcurrentIndexFailed) { runner.migrate }
      failure.index.should eq("index_books_on_isbn")
      failure.message.not_nil!.should contain(%(Remediation: run DROP INDEX CONCURRENTLY "index_books_on_isbn";))
      failure.message.not_nil!.should contain("migration 2 (index_isbn)")
      journal(db).should eq([1_i64])
      db.query_one("SELECT indisvalid FROM pg_index WHERE indexrelid = 'index_books_on_isbn'::regclass", as: Bool).should be_false

      # IF NOT EXISTS now skips the INVALID leftover; the migrator must not journal it.
      expect_raises(SugarORM::Migrator::ConcurrentIndexFailed) { runner.migrate }
      journal(db).should eq([1_i64])

      db.exec(%(DROP INDEX CONCURRENTLY "index_books_on_isbn"))
      db.exec("DELETE FROM books WHERE id = (SELECT max(id) FROM books)")
      runner.migrate.should eq(1)
      db.query_one("SELECT indisvalid FROM pg_index WHERE indexrelid = 'index_books_on_isbn'::regclass", as: Bool).should be_true
    end
  end

  it "lints every pending migration before running any and allows --dev-override only in development" do
    with_scratch_database do |db|
      migrations = [
        migration(1, "create_books", "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, title text NOT NULL)"),
        migration(2, "index_title", "CREATE INDEX index_books_on_title ON books (title)"),
      ]
      warnings = IO::Memory.new
      runner = SugarORM::Migrator.new(db, migrations, warnings)
      runner.lint.map(&.rule).should eq(["concurrent-index"])
      refusal = expect_raises(SugarORM::Linter::Refused) { runner.migrate(environment: "production") }
      refusal.message.not_nil!.should contain("LINT concurrent-index: CREATE INDEX on existing table books")
      expect_raises(SugarORM::Linter::Refused, "--dev-override was ignored") { runner.migrate(dev_override: true, environment: "production") }
      expect_raises(SugarORM::Linter::Refused) { runner.migrate(dev_override: true, environment: "test") }
      db.query_one("SELECT to_regclass('books')::text", as: String?).should be_nil
      db.query_one("SELECT to_regclass('caramel_migrations')::text", as: String?).should be_nil

      runner.migrate(dev_override: true, environment: "development").should eq(2)
      warnings.to_s.should contain("WARN (--dev-override) LINT concurrent-index")
      journal(db).should eq([1_i64, 2_i64])
    end
  end

  it "serializes migrators behind the advisory lock" do
    with_scratch_database do |db|
      create = migration(1, "create_books", "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY)")
      holder = Caramel::Database.open(MIGRATIONS_OWNER_URL.sub("/caramel_spec?", "/#{db.query_one("SELECT current_database()", as: String)}?"), 1)
      begin
        holder.using_connection do |connection|
          connection.exec("SELECT pg_advisory_lock($1)", SugarORM::Migrator::LOCK_ID)
          done = Channel(Int32 | Exception).new(1)
          spawn do
            done.send(SugarORM::Migrator.new(db, [create]).migrate)
          rescue ex
            done.send(ex)
          end
          waiting = false
          20.times do
            sleep 50.milliseconds
            waiting = connection.query_one("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted AND database = (SELECT oid FROM pg_database WHERE datname = current_database())", as: Int64) == 1
            break if waiting
          end
          waiting.should be_true
          connection.query_one("SELECT to_regclass('caramel_migrations')::text", as: String?).should be_nil
          connection.exec("SELECT pg_advisory_unlock($1)", SugarORM::Migrator::LOCK_ID)
          done.receive.should eq(1)
        end
      ensure
        holder.close
      end
    end
  end
end
