require "spec"
require "random/secure"
require "../../src/caramel/database"
require "../../src/sugar_orm/migration"
require "../../src/sugar_orm/differ"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
private def owned_url(name : String, what : String) : String
  ENV[name]? || raise "Run scripts/check integration; no owned #{what} provided"
end

MIGRATIONS_ADMIN_URL = owned_url("CARAMEL_OWNED_ADMIN_URL", "admin connection")
MIGRATIONS_OWNER_URL = owned_url("CARAMEL_OWNED_SPEC_URL", "test database")

private BOOKS_WITH_TITLE = "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY " \
                           "PRIMARY KEY, title text NOT NULL)"
private BOOKS_WITH_ISBN = "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY " \
                          "PRIMARY KEY, isbn text NOT NULL)"
private ISBN_INDEX = %(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ) \
                     %("index_books_on_isbn" ON "books" ("isbn"))
private ISBN_INDEX_VALID = "SELECT indisvalid FROM pg_index " \
                           "WHERE indexrelid = 'index_books_on_isbn'::regclass"
# Sessions of the current database waiting for an advisory lock.
private ADVISORY_WAITERS = "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' " \
                           "AND NOT granted AND database = (SELECT oid FROM pg_database " \
                           "WHERE datname = current_database())"

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

# The relation named `name`, if it exists where `db` connects.
private def relation(db, name : String) : String?
  db.query_one("SELECT to_regclass('#{name}')::text", as: String?)
end

private alias Catalog = SugarORM::Catalog

# Authors and books that belong to an account, each book to an author of its account.
private def tenanted_catalog : Array(Catalog::Table)
  id = Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true)
  account_id = Catalog::Column.new("account_id", "bigint", false, nil)
  author_id = Catalog::Column.new("author_id", "bigint", false, nil)
  [
    Catalog::Table.new("accounts", [id]),
    Catalog::Table.new(
      name: "authors",
      columns: [id, account_id],
      indexes: [tenant_index("authors")],
      foreign_keys: [account_key("authors")],
    ),
    Catalog::Table.new(
      name: "books",
      columns: [id, account_id, author_id],
      indexes: [tenant_index("books")],
      foreign_keys: [
        account_key("books"),
        Catalog::ForeignKey.new(
          name: "fk_books_author_id",
          columns: ["author_id", "account_id"],
          references_table: "authors",
          references_columns: ["id", "account_id"],
        ),
      ],
    ),
  ]
end

private def tenant_index(table : String) : Catalog::Index
  Catalog::Index.new("index_#{table}_on_account_id_and_id", ["account_id", "id"], unique: true)
end

private def account_key(table : String) : Catalog::ForeignKey
  Catalog::ForeignKey.new("fk_#{table}_account_id", ["account_id"], "accounts")
end

describe SugarORM::Migrator do
  it "reads back every declared catalog value after its DDL runs" do
    id = Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true)
    pen_name = Catalog::Column.new("name", "text", false, "'it''s anonymous'")
    author = Catalog::ForeignKey.new(
      "fk_books_author_id", ["author_id"], "authors", on_delete: "CASCADE"
    )
    declared = [
      Catalog::Table.new("authors", [id, pen_name]),
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
      ], [author]),
    ]
    with_scratch_database do |db|
      creation = SugarORM::Differ.diff(declared, [] of Catalog::Table)
      statements = SugarORM::DDL.statements(creation.transactional)
      create = SugarORM::Migration.new(1_i64, "create", statements)
      SugarORM::Migrator.new(db, [create]).migrate.should eq(1)
      snapshot = SugarORM::Introspection.read(db)
      snapshot.tables.reject(&.name.starts_with?("caramel_")).should eq(declared)
      snapshot.invalid_indexes.should be_empty
      plan = SugarORM::Differ.diff(declared, snapshot)
      plan.clean?.should be_true
      plan.notes.should eq(["ignored table caramel_migrations (owned by Caramel)"])
    end
  end

  it "reads back a composite foreign key and the unique index it references" do
    with_scratch_database do |db|
      declared = tenanted_catalog
      creation = SugarORM::Differ.diff(declared, [] of Catalog::Table)
      statements = SugarORM::DDL.statements(creation.transactional)
      create = SugarORM::Migration.new(1_i64, "create", statements)
      SugarORM::Migrator.new(db, [create]).migrate.should eq(1)
      snapshot = SugarORM::Introspection.read(db)
      snapshot.tables.reject(&.name.starts_with?("caramel_")).should eq(declared)
      SugarORM::Differ.diff(declared, snapshot).clean?.should be_true
    end
  end

  it "reads back range and expression checks, so the re-diff of a created table is empty" do
    id = Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true)
    integer = ->(name : String) { Catalog::Column.new(name, "integer", false, nil) }
    moment = ->(name : String) do
      Catalog::Column.new(name, "timestamp with time zone", false, nil)
    end
    checks = [
      Catalog::Check.new("check_shelves_balance", column: "balance", min: -5_i64),
      Catalog::Check.new("check_shelves_big", column: "big", max: 3_000_000_000_i64),
      Catalog::Check.new("check_shelves_dates", expression: "starts_at < ends_at"),
      Catalog::Check.new("check_shelves_limit", column: "limit", max: 10_i64),
      Catalog::Check.new("check_shelves_quantity", column: "quantity", min: 1_i64, max: 10_i64),
      Catalog::Check.new("check_shelves_stock", column: "stock", min: 0_i64),
    ]
    shelves = Catalog::Table.new("shelves", [
      id,
      integer.call("stock"),
      integer.call("quantity"),
      integer.call("balance"),
      Catalog::Column.new("big", "bigint", false, nil),
      integer.call("limit"),
      moment.call("starts_at"),
      moment.call("ends_at"),
    ], checks: checks)
    with_scratch_database do |db|
      creation = SugarORM::Differ.diff([shelves], [] of Catalog::Table)
      creation.online.should be_empty
      statements = SugarORM::DDL.statements(creation.transactional)
      create = SugarORM::Migration.new(1_i64, "create", statements)
      SugarORM::Migrator.new(db, [create]).migrate.should eq(1)
      snapshot = SugarORM::Introspection.read(db)
      live = snapshot.tables.find! { |table| table.name == "shelves" }
      live.checks.reject(&.expression).should eq(checks.reject(&.expression))
      SugarORM::Differ.diff([shelves], snapshot).clean?.should be_true
    end
  end

  it "stops at a check that existing rows break, names it and leaves it NOT VALID" do
    id = Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true)
    copies = Catalog::Column.new("copies", "integer", false, nil)
    check = Catalog::Check.new("check_books_copies", column: "copies", min: 1_i64)
    books = Catalog::Table.new("books", [id, copies])
    declared = [books.copy_with(checks: [check])]
    create = migration(1, "Create books",
      "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, " \
      "copies integer NOT NULL)",
      "INSERT INTO books (copies) VALUES (0)")
    with_scratch_database do |db|
      SugarORM::Migrator.new(db, [create]).migrate.should eq(1)
      plan = SugarORM::Differ.diff(declared, SugarORM::Introspection.read(db))
      add = SugarORM::Migration.new(2_i64, "check", SugarORM::DDL.statements(plan.transactional))
      validate = SugarORM::Migration.new(
        3_i64, "check_concurrently", SugarORM::DDL.statements(plan.online))
      migrations = [create, add, validate]

      error = expect_raises(SugarORM::Migrator::ValidationFailed, "check_books_copies") do
        SugarORM::Migrator.new(db, migrations).migrate
      end
      error.constraint.should eq("check_books_copies")
      error.message.to_s.should contain("Remediation: fix or delete those rows")
      journal(db).should eq([1_i64, 2_i64])
      refused = "INSERT INTO books (copies) VALUES (0)"
      expect_raises(PQ::PQError, /check_books_copies/) { db.exec(refused) }

      db.exec("UPDATE books SET copies = 1")
      SugarORM::Migrator.new(db, migrations).migrate.should eq(1)
      journal(db).should eq([1_i64, 2_i64, 3_i64])
      SugarORM::Differ.diff(declared, SugarORM::Introspection.read(db)).clean?.should be_true
    end
  end

  it "applies transactional migrations once, rolls back a failed batch " \
     "and detects checksum drift" do
    with_scratch_database do |db|
      create = migration(1, "Create books", BOOKS_WITH_TITLE)
      runner = SugarORM::Migrator.new(db, [create])
      runner.pending.map(&.version).should eq([1_i64])
      relation(db, "caramel_migrations").should be_nil
      runner.migrate.should eq(1)
      runner.migrate.should eq(0)
      db.exec("INSERT INTO books (title) VALUES ($1)", "A book")

      probe = "CREATE TABLE rollback_probe (id int)"
      broken = migration(2, "Broken", probe, "INSERT INTO absent_table VALUES (1)")
      expect_raises(PQ::PQError) { SugarORM::Migrator.new(db, [create, broken]).migrate }
      relation(db, "rollback_probe").should be_nil
      journal(db).should eq([1_i64])

      changed = migration(1, "Create books", "CREATE TABLE changed (id int)")
      expect_raises(SugarORM::Migrator::Drift, "has changed") do
        SugarORM::Migrator.new(db, [changed]).pending
      end
      expect_raises(SugarORM::Migrator::Drift, "is missing") do
        SugarORM::Migrator.new(db, [] of SugarORM::Migration).migrate
      end
    end
  end

  it "accepts a journal written by the previous Caramel migrator" do
    with_scratch_database do |db|
      previous_journal = "CREATE TABLE caramel_migrations (version bigint PRIMARY KEY, " \
                         "name text NOT NULL, checksum text NOT NULL, " \
                         "applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP)"
      checksum = "7435dfea99988971c39b6dad7ccbead9e1b6361da715b80c41688e04ae344bcb"
      applied = "INSERT INTO caramel_migrations (version, name, checksum) " \
                "VALUES (1, 'Create books', '#{checksum}')"
      db.exec(previous_journal)
      db.exec(applied)
      create = migration(1, "Create books", BOOKS_WITH_TITLE)
      SugarORM::Migrator.new(db, [create]).pending.should be_empty
    end
  end

  it "runs an all-CONCURRENTLY migration outside a transaction between committed batches" do
    with_scratch_database do |db|
      seed = "INSERT INTO books (isbn) " \
             "SELECT 'isbn-' || n FROM generate_series(1, 500) AS n"
      pages = %(ALTER TABLE "books" ADD COLUMN "pages" integer NOT NULL DEFAULT 0)
      migrations = [
        migration(1, "create_books", BOOKS_WITH_ISBN, seed),
        migration(2, "index_isbn", ISBN_INDEX),
        migration(3, "add_pages", pages),
      ]
      migrations.map(&.transactional?).should eq([true, false, true])
      SugarORM::Migrator.new(db, migrations).migrate.should eq(3)
      unique = "SELECT indisvalid AND indisunique FROM pg_index " \
               "WHERE indexrelid = 'index_books_on_isbn'::regclass"
      db.query_one(unique, as: Bool).should be_true
      journal(db).should eq([1_i64, 2_i64, 3_i64])
      db.query_one("SELECT count(*) FROM books WHERE pages = 0", as: Int64).should eq(500_i64)
    end
  end

  it "names the INVALID index a failed concurrent build leaves and refuses to journal it" do
    with_scratch_database do |db|
      duplicates = "INSERT INTO books (isbn) VALUES ('same'), ('same')"
      create = migration(1, "create_books", BOOKS_WITH_ISBN, duplicates)
      index = migration(2, "index_isbn", ISBN_INDEX)
      runner = SugarORM::Migrator.new(db, [create, index])
      failure = expect_raises(SugarORM::Migrator::ConcurrentIndexFailed) { runner.migrate }
      failure.index.should eq("index_books_on_isbn")
      remedy = %(Remediation: run DROP INDEX CONCURRENTLY "index_books_on_isbn";)
      failure.message.not_nil!.should contain(remedy)
      failure.message.not_nil!.should contain("migration 2 (index_isbn)")
      journal(db).should eq([1_i64])
      db.query_one(ISBN_INDEX_VALID, as: Bool).should be_false

      # IF NOT EXISTS now skips the INVALID leftover; the migrator must not journal it.
      expect_raises(SugarORM::Migrator::ConcurrentIndexFailed) { runner.migrate }
      journal(db).should eq([1_i64])

      db.exec(%(DROP INDEX CONCURRENTLY "index_books_on_isbn"))
      db.exec("DELETE FROM books WHERE id = (SELECT max(id) FROM books)")
      runner.migrate.should eq(1)
      db.query_one(ISBN_INDEX_VALID, as: Bool).should be_true
    end
  end

  it "lints every pending migration before running any " \
     "and allows --dev-override only in development" do
    with_scratch_database do |db|
      migrations = [
        migration(1, "create_books", BOOKS_WITH_TITLE),
        migration(2, "index_title", "CREATE INDEX index_books_on_title ON books (title)"),
      ]
      warnings = IO::Memory.new
      runner = SugarORM::Migrator.new(db, migrations, warnings)
      runner.lint.map(&.rule).should eq(["concurrent-index"])
      refusal = expect_raises(SugarORM::Linter::Refused) do
        runner.migrate(environment: "production")
      end
      lint = "LINT concurrent-index: CREATE INDEX on existing table books"
      refusal.message.not_nil!.should contain(lint)
      expect_raises(SugarORM::Linter::Refused, "--dev-override was ignored") do
        runner.migrate(dev_override: true, environment: "production")
      end
      expect_raises(SugarORM::Linter::Refused) do
        runner.migrate(dev_override: true, environment: "test")
      end
      relation(db, "books").should be_nil
      relation(db, "caramel_migrations").should be_nil

      runner.migrate(dev_override: true, environment: "development").should eq(2)
      warnings.to_s.should contain("WARN (--dev-override) LINT concurrent-index")
      journal(db).should eq([1_i64, 2_i64])
    end
  end

  it "serializes migrators behind the advisory lock" do
    with_scratch_database do |db|
      books = "CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY)"
      create = migration(1, "create_books", books)
      database = db.query_one("SELECT current_database()", as: String)
      url = MIGRATIONS_OWNER_URL.sub("/caramel_spec?", "/#{database}?")
      holder = Caramel::Database.open(url, 1)
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
            waiting = connection.query_one(ADVISORY_WAITERS, as: Int64) == 1
            break if waiting
          end
          waiting.should be_true
          relation(connection, "caramel_migrations").should be_nil
          connection.exec("SELECT pg_advisory_unlock($1)", SugarORM::Migrator::LOCK_ID)
          done.receive.should eq(1)
        end
      ensure
        holder.close
      end
    end
  end
end
