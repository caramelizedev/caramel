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
    rules(%(-- caramel:allow-drop books.other\n#{drop})).should eq(destructive)
    rules(%(-- caramel:allow-drop books.legacy), quoted_drop).should be_empty
    rules(%(ALTER TABLE books DROP CONSTRAINT fk_books_shelf_id)).should be_empty
    rules(%(ALTER TABLE books ALTER COLUMN pages DROP DEFAULT)).should be_empty
    rules(rename).should eq(destructive)
    rules(%(ALTER TABLE teams RENAME email TO billing_email)).should eq(destructive)
    rules(%(-- caramel:allow-rename teams.email\n#{rename})).should be_empty
    rules(%(ALTER TABLE teams RENAME TO crews)).should be_empty
    rules(%(ALTER TABLE teams RENAME CONSTRAINT a TO b)).should be_empty
  end

  it "rejects mixing CONCURRENTLY with statements that need a transaction" do
    mixed = ["mixed-concurrency"]
    build = %(CREATE INDEX CONCURRENTLY index_books_on_isbn ON books (isbn))
    validate = %(ALTER TABLE books VALIDATE CONSTRAINT fk_books_shelf_id)
    drop = %(DROP INDEX CONCURRENTLY IF EXISTS index_books_on_isbn)
    rules(%(ALTER TABLE books ADD COLUMN isbn text), build).should eq(mixed)
    rules(build, validate).should be_empty
    rules(drop, %(DROP INDEX index_books_on_title)).should eq(mixed)
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
    migration("validate", validate).transactional?.should be_false
    migration("mixed", concurrent, update).transactional?.should be_true
    migration("commented", commented).transactional?.should be_true
    migration("named", named).transactional?.should be_true
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
