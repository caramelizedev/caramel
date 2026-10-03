require "spec"
require "../../src/sugar_orm/differ"
require "../../src/sugar_orm/linter"

private alias Catalog = SugarORM::Catalog
private alias Differ = SugarORM::Differ

private def id_column : Catalog::Column
  Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true)
end

# A column that may hold NULL.
private def nullable(name : String,
                     type : String = "text",
                     default : String? = nil,
                     renamed_from : String? = nil) : Catalog::Column
  Catalog::Column.new(name, type, true, default, renamed_from: renamed_from)
end

# A NOT NULL column.
private def required(name : String,
                     type : String = "text",
                     default : String? = nil) : Catalog::Column
  Catalog::Column.new(name, type, false, default)
end

private def books(columns = [] of Catalog::Column,
                  indexes = [] of Catalog::Index,
                  keys = [] of Catalog::ForeignKey,
                  drops = [] of String) : Catalog::Table
  all_columns = [id_column, required("title")] + columns
  Catalog::Table.new("books", all_columns, indexes, keys, drops)
end

private def sql(operations : Array(Differ::Operation)) : Array(String)
  SugarORM::DDL.statements(operations)
end

# The unique index a tenanted *table* gets on its tenant and primary key.
private def tenant_index(table : String) : Catalog::Index
  Catalog::Index.new("index_#{table}_on_account_id_and_id", ["account_id", "id"], unique: true)
end

# A key from *column* and the tenant column to a tenanted *table*.
private def composite_key(name : String, column : String, table : String) : Catalog::ForeignKey
  Catalog::ForeignKey.new(
    name: name,
    columns: [column, "account_id"],
    references_table: table,
    references_columns: ["id", "account_id"],
  )
end

describe SugarORM::Differ do
  it "creates new tables after the new tables they reference, " \
     "with inline indexes and foreign keys" do
    authors = Catalog::Table.new("authors", [id_column])
    author_key = Catalog::ForeignKey.new("fk_books_author_id", ["author_id"], "zines")
    prequel_key = Catalog::ForeignKey.new("fk_books_prequel_id", ["author_id"], "books")
    shelved = Catalog::Table.new(
      name: "books",
      columns: [id_column, nullable("author_id", "bigint")],
      indexes: [Catalog::Index.new("index_books_on_author_id", ["author_id"])],
      foreign_keys: [author_key, prequel_key],
    )
    zines_key = Catalog::ForeignKey.new("fk_zines_author_id", ["id"], "authors")
    zines = Catalog::Table.new("zines", [id_column], foreign_keys: [zines_key])
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
    prequel = %(CONSTRAINT "fk_books_prequel_id" FOREIGN KEY ("author_id") ) \
              %(REFERENCES "books" ("id"))
    statements[2].should contain(prequel)
    migration = SugarORM::Migration.new(1_i64, "create", statements)
    SugarORM::Linter.lint(migration).should be_empty
  end

  it "breaks a foreign key cycle between new tables with constraints added after both" do
    to_right = Catalog::ForeignKey.new("fk_lefts_right_id", ["right_id"], "rights")
    to_left = Catalog::ForeignKey.new("fk_rights_left_id", ["left_id"], "lefts")
    left_columns = [id_column, nullable("right_id", "bigint")]
    right_columns = [id_column, nullable("left_id", "bigint")]
    left = Catalog::Table.new("lefts", left_columns, foreign_keys: [to_right])
    right = Catalog::Table.new("rights", right_columns, foreign_keys: [to_left])
    statements = sql(Differ.diff([left, right], [] of Catalog::Table).transactional)
    statements.size.should eq(3)
    statements[0].should_not contain("CONSTRAINT")
    statements[1].should contain(%(CONSTRAINT "fk_rights_left_id"))
    deferred = %(ALTER TABLE "lefts" ADD CONSTRAINT "fk_lefts_right_id" ) \
               %(FOREIGN KEY ("right_id") REFERENCES "rights" ("id"))
    statements[2].should eq(deferred)
  end

  it "adds a composite key on a new table's own rows after the table's indexes" do
    sequel = composite_key("fk_books_sequel_id", "sequel_id", "books")
    columns = [id_column, required("account_id", "bigint"), nullable("sequel_id", "bigint")]
    table = Catalog::Table.new("books", columns, [tenant_index("books")], [sequel])
    statements = sql(Differ.diff([table], [] of Catalog::Table).transactional)
    statements[0].should_not contain("CONSTRAINT")
    indexed = %(CREATE UNIQUE INDEX "index_books_on_account_id_and_id" ) \
              %(ON "books" ("account_id", "id"))
    deferred = %(ALTER TABLE "books" ADD CONSTRAINT "fk_books_sequel_id" ) \
               %(FOREIGN KEY ("sequel_id", "account_id") ) \
               %(REFERENCES "books" ("id", "account_id"))
    statements[1..].should eq([indexed, deferred])
  end

  it "drops foreign keys before the columns of every table they depend on" do
    author = composite_key("fk_books_author_id", "author_id", "authors")
    plain = Catalog::ForeignKey.new("fk_books_author_id", ["author_id"], "authors")
    account = required("account_id", "bigint")
    author_id = required("author_id", "bigint")
    authors = Catalog::Table.new("authors", [id_column, account], [tenant_index("authors")])
    tenanted = books([author_id, account], [tenant_index("books")], [author])
    actual = [authors, tenanted]
    declared = [
      Catalog::Table.new("authors", [id_column], drops: ["account_id"]),
      books([author_id], keys: [plain], drops: ["account_id"]),
    ]
    sql(Differ.diff(declared, actual).transactional).should eq([
      %(ALTER TABLE "books" DROP CONSTRAINT "fk_books_author_id"),
      %(-- caramel:allow-drop authors.account_id\n) +
      %(ALTER TABLE "authors" DROP COLUMN "account_id"),
      %(-- caramel:allow-drop books.account_id\n) +
      %(ALTER TABLE "books" DROP COLUMN "account_id"),
      %(ALTER TABLE "books" ADD CONSTRAINT "fk_books_author_id" ) +
      %(FOREIGN KEY ("author_id") REFERENCES "authors" ("id") NOT VALID),
    ])
  end

  it "halts a key that would wait on a unique index built afterwards, CONCURRENTLY" do
    account = required("account_id", "bigint")
    author_id = required("author_id", "bigint")
    author = composite_key("fk_books_author_id", "author_id", "authors")
    authors = Catalog::Table.new("authors", [id_column, account])
    declared = [
      authors.copy_with(indexes: [tenant_index("authors")]),
      books([author_id, account], keys: [author]),
    ]
    plan = Differ.diff(declared, [authors, books([author_id, account])])
    plan.halts.map(&.subject).should eq(["books.fk_books_author_id"])
    plan.halts.first.overridable.should be_false
    build = %(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ) \
            %("index_authors_on_account_id_and_id" ON "authors" ("account_id", "id"))
    plan.halts.first.remediation.should contain(build)
  end

  it "reports no work when the database matches, and ignores undeclared and Caramel tables" do
    caramel = Catalog::Table.new("caramel_migrations", [id_column])
    legacy = Catalog::Table.new("legacy_things", [id_column])
    plan = Differ.diff([books], [books, caramel, legacy])
    plan.clean?.should be_true
    plan.notes.should eq([
      "ignored table caramel_migrations (owned by Caramel)",
      "ignored table legacy_things (no schema declares it)",
    ])
  end

  it "adds nullable and defaulted columns but halts a NOT NULL column without a default" do
    declared = books([
      nullable("subtitle"),
      required("pages", "integer", "0"),
      required("isbn"),
    ])
    plan = Differ.diff([declared], [books])
    sql(plan.transactional).should eq([
      %(ALTER TABLE "books" ADD COLUMN "subtitle" text),
      %(ALTER TABLE "books" ADD COLUMN "pages" integer NOT NULL DEFAULT 0),
    ])
    plan.halts.map(&.subject).should eq(["books.isbn"])
    remediation = "Remediation: give the field a default (field isbn : String = …)"
    plan.halts.first.to_s.should contain(remediation)

    overridden = Differ.diff([declared], [books], dev_override: true)
    overridden.halts.should be_empty
    overridden.overridden.map(&.subject).should eq(["books.isbn"])
    added = %(ALTER TABLE "books" ADD COLUMN "isbn" text NOT NULL)
    sql(overridden.transactional).last.should eq(added)
  end

  it "renames a column declared renamed_from and still reconciles its other attributes" do
    billing = nullable("billing_email", default: "'none'", renamed_from: "email")
    declared = books([billing])
    actual = books([required("email")])
    plan = Differ.diff([declared], [actual])
    plan.halts.should be_empty
    rename = %(-- caramel:allow-rename books.email\n) \
             %(ALTER TABLE "books" RENAME COLUMN "email" TO "billing_email")
    sql(plan.transactional).should eq([
      rename,
      %(ALTER TABLE "books" ALTER COLUMN "billing_email" DROP NOT NULL),
      %(ALTER TABLE "books" ALTER COLUMN "billing_email" SET DEFAULT 'none'),
    ])
    renamed = books([nullable("billing_email", default: "'none'")])
    Differ.diff([declared], [renamed]).clean?.should be_true
  end

  it "keeps an index on a renamed column instead of rebuilding it" do
    index_on_code = Catalog::Index.new("index_books_on_isbn", ["code"])
    index_on_isbn = Catalog::Index.new("index_books_on_isbn", ["isbn"])
    declared = books([nullable("code", renamed_from: "isbn")], [index_on_code])
    actual = books([nullable("isbn")], [index_on_isbn])
    plan = Differ.diff([declared], [actual])
    plan.online.should be_empty
    plan.transactional.size.should eq(1)
  end

  it "refuses a rename whose source and target both exist, even with --dev-override" do
    declared = books([nullable("billing_email", renamed_from: "email")])
    actual = books([nullable("email"), nullable("billing_email")])
    plan = Differ.diff([declared], [actual], dev_override: true)
    plan.halts.map(&.subject).should eq(["books.billing_email"])
    plan.halts.first.overridable.should be_false
    plan.empty?.should be_true
  end

  it "drops a column only for an explicit drop_column and halts on any other undeclared column" do
    actual = books([nullable("legacy")])
    dropped = %(ALTER TABLE "books" DROP COLUMN "legacy")
    explicit = Differ.diff([books(drops: ["legacy"])], [actual])
    explicit.halts.should be_empty
    annotated = %(-- caramel:allow-drop books.legacy\n#{dropped})
    sql(explicit.transactional).should eq([annotated])

    halted = Differ.diff([books], [actual])
    halted.empty?.should be_true
    halt = "HALT books.legacy: column exists in the database " \
           "but no field declares it; " \
           "SugarORM never drops a column it was not told to.\n" \
           "  Remediation: declare the field again, " \
           "mark its replacement renamed_from: :legacy, " \
           "or record the intent with drop_column :legacy."
    halted.halts.first.to_s.should eq(halt)
    String.build { |io| halted.halts.first.to_mrdp(io) }.should eq(<<-MRDP)
      ERR DIFF_HALT at books.legacy
      MSG: column exists in the database but no field declares it; \
        SugarORM never drops a column it was not told to.
      FIX: declare the field again, mark its replacement renamed_from: :legacy, \
        or record the intent with drop_column :legacy.\n
      MRDP

    overridden = Differ.diff([books], [actual], dev_override: true)
    sql(overridden.transactional).should eq([dropped])
    migration = SugarORM::Migration.new(1_i64, "drop", sql(overridden.transactional))
    SugarORM::Linter.lint(migration).map(&.rule).should eq(["destructive-column"])
  end

  it "drops NOT NULL and changes defaults safely but halts SET NOT NULL and type changes" do
    declared = books([
      nullable("notes"),
      required("pages", "bigint"),
      required("rating", "integer", "3"),
    ])
    actual = books([
      required("notes", default: "''"),
      nullable("pages", "integer"),
      required("rating", "integer"),
    ])
    plan = Differ.diff([declared], [actual])
    sql(plan.transactional).should eq([
      %(ALTER TABLE "books" ALTER COLUMN "notes" DROP NOT NULL),
      %(ALTER TABLE "books" ALTER COLUMN "notes" DROP DEFAULT),
      %(ALTER TABLE "books" ALTER COLUMN "rating" SET DEFAULT 3),
    ])
    halts = plan.halts.map { |halt| {halt.subject, halt.message.split(' ', 2).first} }
    halts.should eq([{"books.pages", "declared"}, {"books.pages", "SET"}])

    overridden = Differ.diff([declared], [actual], dev_override: true)
    statements = sql(overridden.transactional)
    retyped = %(ALTER TABLE "books" ALTER COLUMN "pages" TYPE bigint USING "pages"::bigint)
    statements.should contain(retyped)
    statements.should contain(%(ALTER TABLE "books" ALTER COLUMN "pages" SET NOT NULL))
  end

  it "never rewrites a primary key, even with --dev-override" do
    plain_id = Catalog::Column.new("id", "bigint", false, nil, primary: true)
    actual = Catalog::Table.new("books", [plain_id, required("title")])
    plan = Differ.diff([books], [actual], dev_override: true)
    plan.halts.map(&.subject).should eq(["books.id"])
    plan.empty?.should be_true
  end

  it "changes indexes on existing tables in a separate CONCURRENTLY migration" do
    actual = books([nullable("isbn"), nullable("legacy")], [
      Catalog::Index.new("index_books_on_isbn", ["isbn"]),
      Catalog::Index.new("index_books_on_title", ["title"]),
      Catalog::Index.new("index_books_on_legacy", ["legacy"]),
    ])
    declared = books([nullable("isbn"), nullable("pages", "integer")], [
      Catalog::Index.new("index_books_on_isbn", ["isbn"], unique: true),
      Catalog::Index.new("index_books_on_pages", ["pages"]),
    ], drops: ["legacy"])
    plan = Differ.diff([declared], [actual])
    sql(plan.transactional).should eq([
      %(ALTER TABLE "books" ADD COLUMN "pages" integer),
      %(-- caramel:allow-drop books.legacy\nALTER TABLE "books" DROP COLUMN "legacy"),
    ])
    sql(plan.online).should eq([
      %(DROP INDEX CONCURRENTLY IF EXISTS "index_books_on_isbn"),
      %(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "index_books_on_isbn" ON "books" ("isbn")),
      %(CREATE INDEX CONCURRENTLY IF NOT EXISTS "index_books_on_pages" ON "books" ("pages")),
      %(DROP INDEX CONCURRENTLY IF EXISTS "index_books_on_title"),
    ])
    migrations = [
      SugarORM::Migration.new(1_i64, "evolve", sql(plan.transactional)),
      SugarORM::Migration.new(2_i64, "evolve_concurrently", sql(plan.online)),
    ]
    migrations.map(&.transactional?).should eq([true, false])
    SugarORM::Linter.lint(migrations).should be_empty
  end

  it "adds a foreign key to an existing table NOT VALID " \
     "and validates it outside that transaction" do
    shelf = Catalog::ForeignKey.new("fk_books_shelf_id", ["shelf_id"], "shelves")
    cascading = Catalog::ForeignKey.new(
      name: "fk_books_shelf_id",
      columns: ["shelf_id"],
      references_table: "shelves",
      on_delete: "CASCADE",
    )
    racks = Catalog::ForeignKey.new("fk_books_old", ["shelf_id"], "racks")
    declared = books([nullable("shelf_id", "bigint")], keys: [shelf])
    stale = books([nullable("shelf_id", "bigint")], keys: [cascading, racks])
    plan = Differ.diff([declared], [stale])
    not_valid = %(ALTER TABLE "books" ADD CONSTRAINT "fk_books_shelf_id" ) \
                %(FOREIGN KEY ("shelf_id") REFERENCES "shelves" ("id") NOT VALID)
    sql(plan.transactional).should eq([
      %(ALTER TABLE "books" DROP CONSTRAINT "fk_books_shelf_id"),
      %(ALTER TABLE "books" DROP CONSTRAINT "fk_books_old"),
      not_valid,
    ])
    validate = %(ALTER TABLE "books" VALIDATE CONSTRAINT "fk_books_shelf_id")
    sql(plan.online).should eq([validate])
    online = SugarORM::Migration.new(2_i64, "validate", sql(plan.online))
    online.transactional?.should be_false
  end

  it "halts on an INVALID index left by a failed concurrent build" do
    skipped = "skipped index lower_title on books " \
              "(expression, partial or constraint index)"
    snapshot = SugarORM::Introspection::Snapshot.new(
      tables: [books],
      invalid_indexes: ["index_books_on_isbn"],
      skipped: [skipped],
    )
    plan = Differ.diff([books], snapshot, dev_override: true)
    halt = %(HALT index_books_on_isbn: index is INVALID, ) \
           %(left behind by a failed CREATE INDEX CONCURRENTLY.\n) \
           %(  Remediation: run DROP INDEX CONCURRENTLY "index_books_on_isbn"; ) \
           %(then diff again.)
    plan.halts.map(&.to_s).should eq([halt])
    plan.notes.should eq([skipped])
  end
end

describe SugarORM::Catalog do
  it "round-trips the schema document the application prints for Frappé" do
    email = nullable("email", default: "'x'", renamed_from: "mail")
    index = Catalog::Index.new("index_books_on_email", ["email"], unique: true)
    key = Catalog::ForeignKey.new(
      name: "fk_books_email",
      columns: ["email", "account_id"],
      references_table: "people",
      references_columns: ["address", "account_id"],
      on_delete: "SET NULL",
    )
    tables = [books([email], [index], [key], ["legacy"])]
    Catalog.from_json(Catalog.to_json(tables)).should eq(tables)
    unnamed = %({"version":2,"tables":[{"name":"x"}]})
    expect_raises(ArgumentError, "invalid schema document") { Catalog.from_json(unnamed) }
  end

  it "refuses a schema document of an earlier version" do
    earlier = %({"version":1,"tables":[]})
    expect_raises(ArgumentError, "unsupported schema document version") do
      Catalog.from_json(earlier)
    end
  end
end

describe SugarORM::Introspection do
  it "spells pg_get_expr constants the way declared defaults are written" do
    normalize = ->(expression : String?, type : String) do
      SugarORM::Introspection.normalize_default(expression, type)
    end
    sequence = "nextval('books_id_seq'::regclass)"
    normalize.call("'x'::text", "text").should eq("'x'")
    normalize.call("'it''s'::text", "text").should eq("'it''s'")
    normalize.call("'-5'::integer", "integer").should eq("-5")
    normalize.call("'-3'::integer", "bigint").should eq("-3")
    normalize.call("'2.5'::double precision", "double precision").should eq("2.5")
    normalize.call("now()", "timestamp with time zone").should eq("CURRENT_TIMESTAMP")
    normalize.call("'5'::text", "integer").should eq("'5'::text")
    normalize.call(sequence, "bigint").should eq(sequence)
    normalize.call(nil, "text").should be_nil
  end
end
