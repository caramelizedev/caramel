require "spec"
require "../../src/sugar_orm/linter"

private def lint(*statements : String) : Array(SugarORM::Linter::Violation)
  SugarORM::Linter.lint(SugarORM::Migration.new(20260101000000_i64, "probe", statements.to_a))
end

private def rules(*statements : String) : Array(String)
  lint(*statements).map(&.rule)
end

describe SugarORM::Linter do
  it "Rule 1: requires CONCURRENTLY for an index on a table the migration did not create" do
    rules(%(CREATE INDEX index_books_on_title ON books (title))).should eq(["concurrent-index"])
    rules(%(create unique index on "Books" (title))).should eq(["concurrent-index"])
    rules(%(CREATE INDEX CONCURRENTLY IF NOT EXISTS index_books_on_title ON books (title))).should be_empty
    rules(%(CREATE TABLE "books" (id bigint)), %(CREATE INDEX index_books_on_id ON books (id))).should be_empty
    rules(%(CREATE TABLE shelves (id bigint)), %(CREATE INDEX index_books_on_id ON books (id))).should eq(["concurrent-index"])
    lint(%(CREATE INDEX index_books_on_title ON public.books (title))).first.message.should contain("existing table books")
  end

  it "Rule 2: rejects ADD COLUMN NOT NULL without a DEFAULT on an existing table" do
    rules(%(ALTER TABLE books ADD COLUMN isbn text NOT NULL)).should eq(["not-null-default"])
    rules(%(ALTER TABLE books ADD isbn text NOT NULL -- DEFAULT comes later)).should eq(["not-null-default"])
    rules(%(ALTER TABLE books ADD COLUMN pages integer, ADD COLUMN isbn text NOT NULL)).should eq(["not-null-default"])
    rules(%(ALTER TABLE books ADD COLUMN isbn text NOT NULL DEFAULT 'none')).should be_empty
    rules(%(ALTER TABLE books ADD COLUMN isbn text DEFAULT 'NOT NULL')).should be_empty
    rules(%(ALTER TABLE books ADD COLUMN isbn text)).should be_empty
    rules(%(ALTER TABLE books ADD CONSTRAINT books_title_present CHECK (title IS NOT NULL) NOT VALID)).should be_empty
    rules(%(CREATE TABLE books (id bigint)), %(ALTER TABLE books ADD COLUMN isbn text NOT NULL)).should be_empty
  end

  it "Rule 3: rejects DROP COLUMN and RENAME COLUMN unless annotated as explicit intent" do
    rules(%(ALTER TABLE books DROP COLUMN legacy)).should eq(["destructive-column"])
    rules(%(ALTER TABLE books DROP legacy CASCADE)).should eq(["destructive-column"])
    rules(%(-- caramel:allow-drop books.legacy\nALTER TABLE books DROP COLUMN legacy)).should be_empty
    rules(%(-- caramel:allow-drop books.other\nALTER TABLE books DROP COLUMN legacy)).should eq(["destructive-column"])
    rules(%(-- caramel:allow-drop books.legacy), %(ALTER TABLE "books" DROP COLUMN IF EXISTS "legacy")).should be_empty
    rules(%(ALTER TABLE books DROP CONSTRAINT fk_books_shelf_id)).should be_empty
    rules(%(ALTER TABLE books ALTER COLUMN pages DROP DEFAULT)).should be_empty
    rules(%(ALTER TABLE teams RENAME COLUMN email TO billing_email)).should eq(["destructive-column"])
    rules(%(ALTER TABLE teams RENAME email TO billing_email)).should eq(["destructive-column"])
    rules(%(-- caramel:allow-rename teams.email\nALTER TABLE teams RENAME COLUMN email TO billing_email)).should be_empty
    rules(%(ALTER TABLE teams RENAME TO crews)).should be_empty
    rules(%(ALTER TABLE teams RENAME CONSTRAINT a TO b)).should be_empty
  end

  it "rejects mixing CONCURRENTLY with statements that need a transaction" do
    rules(%(ALTER TABLE books ADD COLUMN isbn text), %(CREATE INDEX CONCURRENTLY index_books_on_isbn ON books (isbn))).should eq(["mixed-concurrency"])
    rules(%(CREATE INDEX CONCURRENTLY index_books_on_isbn ON books (isbn)), %(ALTER TABLE books VALIDATE CONSTRAINT fk_books_shelf_id)).should be_empty
    rules(%(DROP INDEX CONCURRENTLY IF EXISTS index_books_on_isbn), %(DROP INDEX index_books_on_title)).should eq(["mixed-concurrency"])
  end

  it "prints the rule, the offending statement and a remediation" do
    lint(%(ALTER TABLE books DROP COLUMN legacy)).first.to_s.should eq(<<-TEXT)
      LINT destructive-column: DROP COLUMN legacy destroys the data in books.legacy.
        in migration 20260101000000 (probe):
        │ ALTER TABLE books DROP COLUMN legacy
        Remediation: declare drop_column :legacy in the schema and diff again; hand-written SQL needs the line -- caramel:allow-drop books.legacy
      TEXT
  end

  it "downgrades violations to warnings only for --dev-override in development" do
    violations = lint(%(CREATE INDEX index_books_on_title ON books (title)))
    warnings = IO::Memory.new
    SugarORM::Linter.enforce(violations, dev_override: true, environment: "development", warnings: warnings)
    warnings.to_s.should start_with("WARN (--dev-override) LINT concurrent-index:")

    error = expect_raises(SugarORM::Linter::Refused) { SugarORM::Linter.enforce(violations, dev_override: false, environment: "development", warnings: warnings) }
    error.message.not_nil!.should contain("In development only, --dev-override downgrades")
    {"test", "production", "staging"}.each do |environment|
      error = expect_raises(SugarORM::Linter::Refused) { SugarORM::Linter.enforce(violations, dev_override: true, environment: environment, warnings: warnings) }
      error.message.not_nil!.should contain("--dev-override was ignored: it applies only when CARAMEL_ENV=development (current: #{environment})")
      error.violations.should eq(violations)
    end
    SugarORM::Linter.enforce([] of SugarORM::Linter::Violation, dev_override: false, environment: "production")
  end
end

describe SugarORM::Migration do
  it "rejects blank statements before a migration can be journaled" do
    ["", " \n "].each do |sql|
      expect_raises(ArgumentError) { SugarORM::Migration.new(1_i64, "Empty", [sql]) }
    end
  end

  it "runs outside a transaction only when every statement is online" do
    SugarORM::Migration.new(1_i64, "index", [%(CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON books (isbn)), %(DROP INDEX CONCURRENTLY IF EXISTS j)]).transactional?.should be_false
    SugarORM::Migration.new(1_i64, "validate", [%(ALTER TABLE books VALIDATE CONSTRAINT fk)]).transactional?.should be_false
    SugarORM::Migration.new(1_i64, "mixed", [%(CREATE INDEX CONCURRENTLY i ON books (isbn)), %(UPDATE books SET isbn = '')]).transactional?.should be_true
    SugarORM::Migration.new(1_i64, "commented", [%(-- CREATE INDEX CONCURRENTLY i ON books (isbn)\nCREATE INDEX i ON books (isbn))]).transactional?.should be_true
    SugarORM::Migration.new(1_i64, "named", [%(CREATE INDEX concurrently_built ON books (isbn))]).transactional?.should be_true
  end

  it "keeps the checksum format of journals written by the previous migrator" do
    migration = SugarORM::Migration.new(1_i64, "Create books", ["CREATE TABLE books (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, title text NOT NULL)"])
    migration.checksum.should eq("7435dfea99988971c39b6dad7ccbead9e1b6361da715b80c41688e04ae344bcb")
    SugarORM::Migration.new(1_i64, "a", ["SELECT 1", "SELECT 2"]).checksum.should_not eq(SugarORM::Migration.new(1_i64, "a", ["SELECT 1SELECT 2"]).checksum)
  end
end
