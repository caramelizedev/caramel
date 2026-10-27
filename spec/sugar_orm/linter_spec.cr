require "spec"
require "../../src/sugar_orm/linter"

private alias Refused = SugarORM::Linter::Refused

private def lint(*statements : String) : Array(SugarORM::Linter::Violation)
  migration = SugarORM::Migration.new(20260101000000_i64, "probe", statements.to_a)
  SugarORM::Linter.lint(migration)
end

private def rules(*statements : String) : Array(String)
  lint(*statements).map(&.rule)
end

private def enforce(violations : Array(SugarORM::Linter::Violation),
                    environment : String,
                    warnings : IO,
                    *,
                    dev_override : Bool) : Nil
  SugarORM::Linter.enforce(
    violations,
    dev_override: dev_override,
    environment: environment,
    warnings: warnings,
  )
end

private def migration(name : String, *statements : String) : SugarORM::Migration
  SugarORM::Migration.new(1_i64, name, statements.to_a)
end

describe SugarORM::Linter do
  it "Rule 1: requires CONCURRENTLY for an index on a table the migration did not create" do
    blocking = ["concurrent-index"]
    online = %(CREATE INDEX CONCURRENTLY IF NOT EXISTS ) \
             %(index_books_on_title ON books (title))
    index_on_id = %(CREATE INDEX index_books_on_id ON books (id))
    qualified = %(CREATE INDEX index_books_on_title ON public.books (title))
    rules(%(CREATE INDEX index_books_on_title ON books (title))).should eq(blocking)
    rules(%(create unique index on "Books" (title))).should eq(blocking)
    rules(online).should be_empty
    rules(%(CREATE TABLE "books" (id bigint)), index_on_id).should be_empty
    rules(%(CREATE TABLE shelves (id bigint)), index_on_id).should eq(blocking)
    rules(%(-- caramel:allow concurrent-index books\n#{index_on_id})).should be_empty
    rules(%(-- caramel:allow concurrent-index shelves\n#{index_on_id})).should eq(blocking)
    lint(qualified).first.message.should contain("existing table books")
  end

  it "Rule 2: rejects ADD COLUMN NOT NULL without a DEFAULT on an existing table" do
    refused = ["not-null-default"]
    add_isbn = %(ALTER TABLE books ADD COLUMN isbn text NOT NULL)
    commented = %(ALTER TABLE books ADD isbn text NOT NULL -- DEFAULT comes later)
    second = %(ALTER TABLE books ADD COLUMN pages integer, ADD COLUMN isbn text NOT NULL)
    check = %(ALTER TABLE books ADD CONSTRAINT books_title_present ) \
            %(CHECK (title IS NOT NULL) NOT VALID)
    rules(add_isbn).should eq(refused)
    rules(commented).should eq(refused)
    rules(second).should eq(refused)
    rules(%(ALTER TABLE books ADD COLUMN isbn text NOT NULL DEFAULT 'none')).should be_empty
    rules(%(ALTER TABLE books ADD COLUMN isbn text DEFAULT 'NOT NULL')).should be_empty
    rules(%(ALTER TABLE books ADD COLUMN isbn text)).should be_empty
    rules(check).should be_empty
    rules(%(CREATE TABLE books (id bigint)), add_isbn).should be_empty
  end

  it "Rule 3: rejects DROP COLUMN and RENAME COLUMN unless annotated as explicit intent" do
    destructive = ["destructive-column"]
    drop = %(ALTER TABLE books DROP COLUMN legacy)
    quoted_drop = %(ALTER TABLE "books" DROP COLUMN IF EXISTS "legacy")
    rename = %(ALTER TABLE teams RENAME COLUMN email TO billing_email)
    rules(drop).should eq(destructive)
    rules(%(ALTER TABLE books DROP legacy CASCADE)).should eq(destructive)
    rules(%(-- caramel:allow-drop books.legacy\n#{drop})).should be_empty
    rules(%(-- caramel:allow destructive-column books.legacy\n#{drop})).should be_empty
    rules(%(-- caramel:allow-drop books.other\n#{drop})).should eq(destructive)
    rules(%(-- caramel:allow-drop books.legacy), quoted_drop).should be_empty
    rules(%(ALTER TABLE books DROP CONSTRAINT fk_books_shelf_id)).should be_empty
    rules(%(ALTER TABLE books ALTER COLUMN pages DROP DEFAULT)).should be_empty
    rules(rename).should eq(destructive)
    rules(%(ALTER TABLE teams RENAME email TO billing_email)).should eq(destructive)
    rules(%(-- caramel:allow-rename teams.email\n#{rename})).should be_empty
    rules(%(ALTER TABLE teams RENAME TO crews)).should eq(["rename-table"])
    rules(%(ALTER TABLE teams RENAME CONSTRAINT a TO b)).should be_empty
  end

  it "rejects DROP TABLE and TRUNCATE of a table the migration did not create" do
    drop = %(DROP TABLE IF EXISTS books CASCADE)
    truncate = %(TRUNCATE TABLE ONLY public.books RESTART IDENTITY)
    create = %(CREATE TABLE books (id bigint))
    rules(drop).should eq(["drop-table"])
    rules(%(truncate books, shelves)).should eq(["truncate"])
    rules(truncate).should eq(["truncate"])
    rules(create, drop).should be_empty
    rules(create, truncate).should be_empty
    rules(%(-- caramel:allow drop-table books\n#{drop})).should be_empty
    rules(%(-- caramel:allow truncate books), truncate).should be_empty
    rules(%(-- caramel:allow truncate shelves), truncate).should eq(["truncate"])
    lint(drop).first.message.should eq("DROP TABLE books destroys the table and every row in it.")
  end

  it "rejects RENAME TO of an existing table" do
    rename = %(ALTER TABLE IF EXISTS teams RENAME TO crews)
    rules(rename).should eq(["rename-table"])
    rules(%(CREATE TABLE teams (id bigint)), rename).should be_empty
    rules(%(-- caramel:allow rename-table teams\n#{rename})).should be_empty
    lint(rename).first.message.should contain("RENAME TO crews breaks the binary still serving")
  end

  it "rejects ALTER COLUMN TYPE on an existing table" do
    retype = %(ALTER TABLE books ALTER COLUMN pages TYPE bigint USING pages::bigint)
    rules(retype).should eq(["alter-column-type"])
    rules(%(ALTER TABLE books ALTER pages SET DATA TYPE bigint)).should eq(["alter-column-type"])
    rules(%(CREATE TABLE books (pages int)), retype).should be_empty
    rules(%(-- caramel:allow alter-column-type books.pages\n#{retype})).should be_empty
    other = %(-- caramel:allow alter-column-type books.other\n#{retype})
    rules(other).should eq(["alter-column-type"])
    lint(retype).first.remediation.should contain("-- caramel:allow alter-column-type books.pages")
  end

  it "rejects SET NOT NULL on an existing table" do
    tighten = %(ALTER TABLE books ALTER COLUMN isbn SET NOT NULL)
    rules(tighten).should eq(["set-not-null"])
    rules(%(ALTER TABLE books ALTER isbn SET NOT NULL)).should eq(["set-not-null"])
    rules(%(ALTER TABLE books ALTER COLUMN isbn DROP NOT NULL)).should be_empty
    rules(%(CREATE TABLE books (isbn text)), tighten).should be_empty
    rules(%(-- caramel:allow set-not-null books.isbn\n#{tighten})).should be_empty
    lint(tighten).first.remediation.should contain("CHECK (isbn IS NOT NULL) NOT VALID")
  end

  it "rejects constraints that scan or build an index while the table is locked" do
    scanning = ["constraint-not-valid"]
    check = %(ALTER TABLE books ADD CONSTRAINT check_books_copies CHECK (copies >= 0))
    key = %(ALTER TABLE books ADD FOREIGN KEY (shelf_id) REFERENCES shelves (id))
    unique = %(ALTER TABLE books ADD CONSTRAINT books_isbn_key UNIQUE (isbn))
    primary = %(ALTER TABLE books ADD PRIMARY KEY (id))
    rules(check).should eq(scanning)
    rules("#{check} NOT VALID").should be_empty
    rules(key).should eq(scanning)
    rules("#{key} ON DELETE CASCADE NOT VALID").should be_empty
    rules(unique).should eq(scanning)
    adopted = %(ALTER TABLE books ADD CONSTRAINT books_isbn_key UNIQUE USING INDEX isbn)
    rules(adopted).should be_empty
    rules(primary).should eq(scanning)
    rules(%(ALTER TABLE books ADD PRIMARY KEY USING INDEX books_pkey)).should be_empty
    rules(%(CREATE TABLE books (id bigint)), check, unique).should be_empty
    rules(%(-- caramel:allow constraint-not-valid books\n#{check}), key).should be_empty
    lint(check).first.message.should start_with("ADD CONSTRAINT check_books_copies CHECK scans")
    lint(unique).first.remediation.should contain("ADD CONSTRAINT … UNIQUE USING INDEX")
  end

  it "rejects DROP INDEX without CONCURRENTLY unless the migration built the index" do
    drop = %(DROP INDEX IF EXISTS public.index_books_on_title)
    rules(drop).should eq(["concurrent-drop-index"])
    rules(%(DROP INDEX CONCURRENTLY index_books_on_title)).should be_empty
    built = %(CREATE INDEX index_books_on_title ON books (title))
    rules(built, drop).should eq(["concurrent-index"])
    rules(%(-- caramel:allow concurrent-drop-index index_books_on_title\n#{drop})).should be_empty
    lint(drop).first.remediation.should contain("use DROP INDEX CONCURRENTLY")
  end

  it "rejects bulk UPDATE and DELETE on an existing table" do
    update = %(UPDATE books AS b SET isbn = '' WHERE b.isbn IS NULL)
    delete = %(DELETE FROM ONLY books WHERE isbn = '')
    rules(update).should eq(["bulk-write"])
    rules(%(UPDATE books SET isbn = '')).should eq(["bulk-write"])
    rules(delete).should eq(["bulk-write"])
    rules(%(INSERT INTO books (isbn) VALUES (''))).should be_empty
    rules(%(CREATE TABLE books (isbn text)), update, delete).should be_empty
    rules(%(-- caramel:allow bulk-write books\n#{update})).should be_empty
    lint(delete).first.message.should start_with("DELETE FROM books rewrites its matching rows")
  end

  it "reads the statements of a DO block but not the body of a CREATE FUNCTION" do
    hidden = <<-SQL
      DO $$
      BEGIN
        IF true THEN
          ALTER TABLE books DROP COLUMN legacy;
        END IF;
      END
      $$
      SQL
    tagged = %(DO LANGUAGE plpgsql $do$ BEGIN DELETE FROM books; END $do$)
    function = %(CREATE FUNCTION purge() RETURNS void LANGUAGE sql AS $$ DELETE FROM books $$)
    rules(hidden).should eq(["hidden-ddl"])
    rules(tagged).should eq(["hidden-ddl"])
    rules(function).should be_empty
    rules(%(CREATE TABLE books (id bigint)), tagged).should be_empty
    rules(%(-- caramel:allow destructive-column books.legacy\n#{hidden})).should be_empty
    violation = lint(hidden).first
    violation.message.should eq(
      "DO block hides destructive-column: DROP COLUMN legacy destroys the data in books.legacy.")
    violation.remediation.should start_with("write the statement outside the DO block; declare")
  end

  it "keeps quoted text as written and reads no statement out of it" do
    escaped = %(DO $$ BEGIN INSERT INTO books (title) VALUES (E'a\\'; DROP TABLE books;'); END $$)
    doubled = %(DO $$ BEGIN INSERT INTO books (title) VALUES ('a''; DROP TABLE books;'); END $$)
    validated = %(ALTER TABLE "a  b" /* comment */ VALIDATE\n\tCONSTRAINT "c")
    rules(escaped).should be_empty
    rules(doubled).should be_empty
    rules(%(DO $$ BEGIN INSERT INTO books (title) VALUES ('a'); DROP TABLE books; END $$))
      .should eq(["hidden-ddl"])
    SugarORM::Linter.validated_constraint(validated).should eq({"a  b", "c"})
  end

  it "rejects mixing CONCURRENTLY with statements that need a transaction" do
    mixed = ["mixed-concurrency"]
    build = %(CREATE INDEX CONCURRENTLY index_books_on_isbn ON books (isbn))
    validate = %(ALTER TABLE books VALIDATE CONSTRAINT fk_books_shelf_id)
    drop = %(DROP INDEX CONCURRENTLY IF EXISTS index_books_on_isbn)
    rules(%(ALTER TABLE books ADD COLUMN isbn text), build).should eq(mixed)
    rules(build, validate).should be_empty
    rules(drop, %(DROP INDEX index_books_on_title)).should eq(["concurrent-drop-index"] + mixed)
  end

  it "prints the rule, the offending statement and a remediation" do
    lint(%(ALTER TABLE books DROP COLUMN legacy)).first.to_s.should eq(<<-TEXT)
      LINT destructive-column: DROP COLUMN legacy destroys the data in books.legacy.
        in migration 20260101000000 (probe):
        │ ALTER TABLE books DROP COLUMN legacy
        Remediation: declare drop_column :legacy in the schema and diff again; \
          hand-written SQL needs the line -- caramel:allow-drop books.legacy
      TEXT
  end

  it "downgrades violations to warnings only for --dev-override in development" do
    violations = lint(%(CREATE INDEX index_books_on_title ON books (title)))
    warnings = IO::Memory.new
    enforce(violations, "development", warnings, dev_override: true)
    warnings.to_s.should start_with("WARN (--dev-override) LINT concurrent-index:")

    error = expect_raises(Refused) do
      enforce(violations, "development", warnings, dev_override: false)
    end
    error.message.not_nil!.should contain("In development only, --dev-override downgrades")
    {"test", "production", "staging"}.each do |environment|
      error = expect_raises(Refused) do
        enforce(violations, environment, warnings, dev_override: true)
      end
      ignored = "--dev-override was ignored: it applies only when " \
                "CARAMEL_ENV=development (current: #{environment})"
      error.message.not_nil!.should contain(ignored)
      error.violations.should eq(violations)
    end
    none = [] of SugarORM::Linter::Violation
    SugarORM::Linter.enforce(none, dev_override: false, environment: "production")
  end

  it "reports a violation as MRDP at the file that declared its migration" do
    violation = lint(%(ALTER TABLE books ADD COLUMN isbn text NOT NULL)).first
    violation.file.should eq(__FILE__)
    String.build { |io| violation.to_mrdp(io, File.dirname(__DIR__)) }.should eq(<<-MRDP)
      ERR LINT_NOT_NULL_DEFAULT at sugar_orm/linter_spec.cr
      MSG: ADD COLUMN isbn NOT NULL without a DEFAULT fails on a populated books table.
      FIX: give the column a DEFAULT, or add it nullable, backfill it, and tighten it later.\n
      MRDP
  end
end

describe SugarORM::Migration do
  it "rejects blank statements before a migration can be journaled" do
    ["", " \n "].each do |sql|
      expect_raises(ArgumentError) { SugarORM::Migration.new(1_i64, "Empty", [sql]) }
    end
  end

  it "runs outside a transaction only when every statement is online" do
    build = %(CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON books (isbn))
    drop = %(DROP INDEX CONCURRENTLY IF EXISTS j)
    validate = %(ALTER TABLE books VALIDATE CONSTRAINT fk)
    concurrent = %(CREATE INDEX CONCURRENTLY i ON books (isbn))
    update = %(UPDATE books SET isbn = '')
    commented = %(-- CREATE INDEX CONCURRENTLY i ON books (isbn)\n) \
                %(CREATE INDEX i ON books (isbn))
    named = %(CREATE INDEX concurrently_built ON books (isbn))
    migration("index", build, drop).transactional?.should be_false
    swap = migration("swap",
      %(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "a_swap" ON "books" ("isbn")),
      %(DROP INDEX CONCURRENTLY IF EXISTS "a"),
      %(ALTER INDEX "a_swap" RENAME TO "a"))
    swap.transactional?.should be_false
    SugarORM::Linter.lint([swap]).should be_empty
    migration("validate", validate).transactional?.should be_false
    migration("mixed", concurrent, update).transactional?.should be_true
    migration("commented", commented).transactional?.should be_true
    migration("named", named).transactional?.should be_true
  end

  it "names the table and constraint of a lone VALIDATE CONSTRAINT" do
    validate = %(ALTER TABLE "books" VALIDATE CONSTRAINT "check_books_copies")
    add = %(ALTER TABLE "books" ADD CONSTRAINT "check_books_copies" CHECK ("copies" >= 0))
    SugarORM::Linter.validated_constraint(validate).should eq({"books", "check_books_copies"})
    SugarORM::Linter.validated_constraint(add).should be_nil
  end

  it "keeps the checksum format of journals written by the previous migrator" do
    create = "CREATE TABLE books " \
             "(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, title text NOT NULL)"
    journaled = "7435dfea99988971c39b6dad7ccbead9e1b6361da715b80c41688e04ae344bcb"
    migration("Create books", create).checksum.should eq(journaled)
    separate = migration("a", "SELECT 1", "SELECT 2").checksum
    separate.should_not eq(migration("a", "SELECT 1SELECT 2").checksum)
  end
end
