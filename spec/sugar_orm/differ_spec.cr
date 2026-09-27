require "spec"
require "../../src/sugar_orm/differ"
require "../../src/sugar_orm/linter"

private alias Catalog = SugarORM::Catalog
private alias Differ = SugarORM::Differ

private def id_column : Catalog::Column
  Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true)
end

private def books(columns = [] of Catalog::Column, indexes = [] of Catalog::Index, keys = [] of Catalog::ForeignKey, drops = [] of String) : Catalog::Table
  Catalog::Table.new("books", [id_column, Catalog::Column.new("title", "text", false, nil)] + columns, indexes, keys, drops)
end

private def sql(operations : Array(Differ::Operation)) : Array(String)
  SugarORM::DDL.statements(operations)
end

describe SugarORM::Differ do
  it "creates new tables after the new tables they reference, with inline indexes and foreign keys" do
    authors = Catalog::Table.new("authors", [id_column])
    shelved = Catalog::Table.new("books", [id_column, Catalog::Column.new("author_id", "bigint", true, nil)],
      [Catalog::Index.new("index_books_on_author_id", ["author_id"])],
      [Catalog::ForeignKey.new("fk_books_author_id", "author_id", "zines"), Catalog::ForeignKey.new("fk_books_prequel_id", "author_id", "books")])
    zines = Catalog::Table.new("zines", [id_column], foreign_keys: [Catalog::ForeignKey.new("fk_zines_author_id", "id", "authors")])
    plan = Differ.diff([authors, shelved, zines], [] of Catalog::Table)
    plan.online.should be_empty
    plan.halts.should be_empty
    statements = sql(plan.transactional)
    statements.map(&.lines.first).should eq([
      "CREATE TABLE \"authors\" (",
      "CREATE TABLE \"zines\" (",
      "CREATE TABLE \"books\" (",
      %(CREATE INDEX "index_books_on_author_id" ON "books" ("author_id")),
    ])
    statements[2].should contain(%(CONSTRAINT "fk_books_prequel_id" FOREIGN KEY ("author_id") REFERENCES "books" ("id")))
    SugarORM::Linter.lint(SugarORM::Migration.new(1_i64, "create", statements)).should be_empty
  end

  it "breaks a foreign key cycle between new tables with constraints added after both" do
    left = Catalog::Table.new("lefts", [id_column, Catalog::Column.new("right_id", "bigint", true, nil)], foreign_keys: [Catalog::ForeignKey.new("fk_lefts_right_id", "right_id", "rights")])
    right = Catalog::Table.new("rights", [id_column, Catalog::Column.new("left_id", "bigint", true, nil)], foreign_keys: [Catalog::ForeignKey.new("fk_rights_left_id", "left_id", "lefts")])
    statements = sql(Differ.diff([left, right], [] of Catalog::Table).transactional)
    statements.size.should eq(3)
    statements[0].should_not contain("CONSTRAINT")
    statements[1].should contain(%(CONSTRAINT "fk_rights_left_id"))
    statements[2].should eq(%(ALTER TABLE "lefts" ADD CONSTRAINT "fk_lefts_right_id" FOREIGN KEY ("right_id") REFERENCES "rights" ("id")))
  end

  it "reports no work when the database matches, and ignores undeclared and Caramel tables" do
    plan = Differ.diff([books], [books, Catalog::Table.new("caramel_migrations", [id_column]), Catalog::Table.new("legacy_things", [id_column])])
    plan.clean?.should be_true
    plan.notes.should eq(["ignored table caramel_migrations (owned by Caramel)", "ignored table legacy_things (no schema declares it)"])
  end

  it "adds nullable and defaulted columns but halts a NOT NULL column without a default" do
    declared = books([Catalog::Column.new("subtitle", "text", true, nil), Catalog::Column.new("pages", "integer", false, "0"), Catalog::Column.new("isbn", "text", false, nil)])
    plan = Differ.diff([declared], [books])
    sql(plan.transactional).should eq([%(ALTER TABLE "books" ADD COLUMN "subtitle" text), %(ALTER TABLE "books" ADD COLUMN "pages" integer NOT NULL DEFAULT 0)])
    plan.halts.map(&.subject).should eq(["books.isbn"])
    plan.halts.first.to_s.should contain("Remediation: give the field a default (field isbn : String = …)")

    overridden = Differ.diff([declared], [books], dev_override: true)
    overridden.halts.should be_empty
    overridden.overridden.map(&.subject).should eq(["books.isbn"])
    sql(overridden.transactional).last.should eq(%(ALTER TABLE "books" ADD COLUMN "isbn" text NOT NULL))
  end

  it "renames a column declared renamed_from and still reconciles its other attributes" do
    declared = books([Catalog::Column.new("billing_email", "text", true, "'none'", renamed_from: "email")])
    actual = books([Catalog::Column.new("email", "text", false, nil)])
    plan = Differ.diff([declared], [actual])
    plan.halts.should be_empty
    sql(plan.transactional).should eq([
      %(-- caramel:allow-rename books.email\nALTER TABLE "books" RENAME COLUMN "email" TO "billing_email"),
      %(ALTER TABLE "books" ALTER COLUMN "billing_email" DROP NOT NULL),
      %(ALTER TABLE "books" ALTER COLUMN "billing_email" SET DEFAULT 'none'),
    ])
    Differ.diff([declared], [books([Catalog::Column.new("billing_email", "text", true, "'none'")])]).clean?.should be_true
  end

  it "keeps an index on a renamed column instead of rebuilding it" do
    declared = books([Catalog::Column.new("code", "text", true, nil, renamed_from: "isbn")], [Catalog::Index.new("index_books_on_isbn", ["code"])])
    actual = books([Catalog::Column.new("isbn", "text", true, nil)], [Catalog::Index.new("index_books_on_isbn", ["isbn"])])
    plan = Differ.diff([declared], [actual])
    plan.online.should be_empty
    plan.transactional.size.should eq(1)
  end

  it "refuses a rename whose source and target both exist, even with --dev-override" do
    declared = books([Catalog::Column.new("billing_email", "text", true, nil, renamed_from: "email")])
    actual = books([Catalog::Column.new("email", "text", true, nil), Catalog::Column.new("billing_email", "text", true, nil)])
    plan = Differ.diff([declared], [actual], dev_override: true)
    plan.halts.map(&.subject).should eq(["books.billing_email"])
    plan.halts.first.overridable.should be_false
    plan.empty?.should be_true
  end

  it "drops a column only for an explicit drop_column and halts on any other undeclared column" do
    actual = books([Catalog::Column.new("legacy", "text", true, nil)])
    explicit = Differ.diff([books(drops: ["legacy"])], [actual])
    explicit.halts.should be_empty
    sql(explicit.transactional).should eq([%(-- caramel:allow-drop books.legacy\nALTER TABLE "books" DROP COLUMN "legacy")])

    halted = Differ.diff([books], [actual])
    halted.empty?.should be_true
    halted.halts.first.to_s.should eq("HALT books.legacy: column exists in the database but no field declares it; SugarORM never drops a column it was not told to.\n  Remediation: declare the field again, mark its replacement renamed_from: :legacy, or record the intent with drop_column :legacy.")
    String.build { |io| halted.halts.first.to_mrdp(io) }.should eq(<<-MRDP)
      ERR DIFF_HALT at books.legacy
      MSG: column exists in the database but no field declares it; SugarORM never drops a column it was not told to.
      FIX: declare the field again, mark its replacement renamed_from: :legacy, or record the intent with drop_column :legacy.\n
      MRDP

    overridden = Differ.diff([books], [actual], dev_override: true)
    sql(overridden.transactional).should eq([%(ALTER TABLE "books" DROP COLUMN "legacy")])
    SugarORM::Linter.lint(SugarORM::Migration.new(1_i64, "drop", sql(overridden.transactional))).map(&.rule).should eq(["destructive-column"])
  end

  it "drops NOT NULL and changes defaults safely but halts SET NOT NULL and type changes" do
    declared = books([Catalog::Column.new("notes", "text", true, nil), Catalog::Column.new("pages", "bigint", false, nil), Catalog::Column.new("rating", "integer", false, "3")])
    actual = books([Catalog::Column.new("notes", "text", false, "''"), Catalog::Column.new("pages", "integer", true, nil), Catalog::Column.new("rating", "integer", false, nil)])
    plan = Differ.diff([declared], [actual])
    sql(plan.transactional).should eq([
      %(ALTER TABLE "books" ALTER COLUMN "notes" DROP NOT NULL),
      %(ALTER TABLE "books" ALTER COLUMN "notes" DROP DEFAULT),
      %(ALTER TABLE "books" ALTER COLUMN "rating" SET DEFAULT 3),
    ])
    plan.halts.map { |halt| {halt.subject, halt.message.split(' ', 2).first} }.should eq([{"books.pages", "declared"}, {"books.pages", "SET"}])

    overridden = Differ.diff([declared], [actual], dev_override: true)
    sql(overridden.transactional).should contain(%(ALTER TABLE "books" ALTER COLUMN "pages" TYPE bigint USING "pages"::bigint))
    sql(overridden.transactional).should contain(%(ALTER TABLE "books" ALTER COLUMN "pages" SET NOT NULL))
  end

  it "never rewrites a primary key, even with --dev-override" do
    actual = Catalog::Table.new("books", [Catalog::Column.new("id", "bigint", false, nil, primary: true), Catalog::Column.new("title", "text", false, nil)])
    plan = Differ.diff([books], [actual], dev_override: true)
    plan.halts.map(&.subject).should eq(["books.id"])
    plan.empty?.should be_true
  end

  it "changes indexes on existing tables in a separate CONCURRENTLY migration" do
    actual = books([Catalog::Column.new("isbn", "text", true, nil), Catalog::Column.new("legacy", "text", true, nil)],
      [Catalog::Index.new("index_books_on_isbn", ["isbn"]), Catalog::Index.new("index_books_on_title", ["title"]), Catalog::Index.new("index_books_on_legacy", ["legacy"])])
    declared = books([Catalog::Column.new("isbn", "text", true, nil), Catalog::Column.new("pages", "integer", true, nil)],
      [Catalog::Index.new("index_books_on_isbn", ["isbn"], unique: true), Catalog::Index.new("index_books_on_pages", ["pages"])], drops: ["legacy"])
    plan = Differ.diff([declared], [actual])
    sql(plan.transactional).should eq([%(ALTER TABLE "books" ADD COLUMN "pages" integer), %(-- caramel:allow-drop books.legacy\nALTER TABLE "books" DROP COLUMN "legacy")])
    sql(plan.online).should eq([
      %(DROP INDEX CONCURRENTLY IF EXISTS "index_books_on_isbn"),
      %(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "index_books_on_isbn" ON "books" ("isbn")),
      %(CREATE INDEX CONCURRENTLY IF NOT EXISTS "index_books_on_pages" ON "books" ("pages")),
      %(DROP INDEX CONCURRENTLY IF EXISTS "index_books_on_title"),
    ])
    migrations = [SugarORM::Migration.new(1_i64, "evolve", sql(plan.transactional)), SugarORM::Migration.new(2_i64, "evolve_concurrently", sql(plan.online))]
    migrations.map(&.transactional?).should eq([true, false])
    SugarORM::Linter.lint(migrations).should be_empty
  end

  it "adds a foreign key to an existing table NOT VALID and validates it outside that transaction" do
    declared = books([Catalog::Column.new("shelf_id", "bigint", true, nil)], keys: [Catalog::ForeignKey.new("fk_books_shelf_id", "shelf_id", "shelves")])
    stale = books([Catalog::Column.new("shelf_id", "bigint", true, nil)], keys: [Catalog::ForeignKey.new("fk_books_shelf_id", "shelf_id", "shelves", on_delete: "CASCADE"), Catalog::ForeignKey.new("fk_books_old", "shelf_id", "racks")])
    plan = Differ.diff([declared], [stale])
    sql(plan.transactional).should eq([
      %(ALTER TABLE "books" DROP CONSTRAINT "fk_books_shelf_id"),
      %(ALTER TABLE "books" DROP CONSTRAINT "fk_books_old"),
      %(ALTER TABLE "books" ADD CONSTRAINT "fk_books_shelf_id" FOREIGN KEY ("shelf_id") REFERENCES "shelves" ("id") NOT VALID),
    ])
    sql(plan.online).should eq([%(ALTER TABLE "books" VALIDATE CONSTRAINT "fk_books_shelf_id")])
    SugarORM::Migration.new(2_i64, "validate", sql(plan.online)).transactional?.should be_false
  end

  it "halts on an INVALID index left by a failed concurrent build" do
    snapshot = SugarORM::Introspection::Snapshot.new([books], ["index_books_on_isbn"], ["skipped index lower_title on books (expression, partial or constraint index)"])
    plan = Differ.diff([books], snapshot, dev_override: true)
    plan.halts.map(&.to_s).should eq([%(HALT index_books_on_isbn: index is INVALID, left behind by a failed CREATE INDEX CONCURRENTLY.\n  Remediation: run DROP INDEX CONCURRENTLY "index_books_on_isbn"; then diff again.)])
    plan.notes.should eq(["skipped index lower_title on books (expression, partial or constraint index)"])
  end
end

describe SugarORM::Catalog do
  it "round-trips the schema document the application prints for Frappé" do
    tables = [books([Catalog::Column.new("email", "text", true, "'x'", renamed_from: "mail")], [Catalog::Index.new("index_books_on_email", ["email"], unique: true)],
      [Catalog::ForeignKey.new("fk_books_email", "email", "people", "address", "SET NULL")], ["legacy"])]
    Catalog.from_json(Catalog.to_json(tables)).should eq(tables)
    expect_raises(ArgumentError, "invalid schema document") { Catalog.from_json(%({"version":1,"tables":[{"name":"x"}]})) }
  end
end

describe SugarORM::Introspection do
  it "spells pg_get_expr constants the way declared defaults are written" do
    normalize = ->(expression : String?, type : String) { SugarORM::Introspection.normalize_default(expression, type) }
    normalize.call("'x'::text", "text").should eq("'x'")
    normalize.call("'it''s'::text", "text").should eq("'it''s'")
    normalize.call("'-5'::integer", "integer").should eq("-5")
    normalize.call("'-3'::integer", "bigint").should eq("-3")
    normalize.call("'2.5'::double precision", "double precision").should eq("2.5")
    normalize.call("now()", "timestamp with time zone").should eq("CURRENT_TIMESTAMP")
    normalize.call("'5'::text", "integer").should eq("'5'::text")
    normalize.call("nextval('books_id_seq'::regclass)", "bigint").should eq("nextval('books_id_seq'::regclass)")
    normalize.call(nil, "text").should be_nil
  end
end
