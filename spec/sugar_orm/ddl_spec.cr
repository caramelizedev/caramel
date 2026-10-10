require "spec"
require "../../src/sugar_orm/ddl"

private alias Catalog = SugarORM::Catalog
private alias Differ = SugarORM::Differ
private alias DDL = SugarORM::DDL

describe SugarORM::DDL do
  it "renders a table with an identity key, defaults, nullability and inline foreign keys" do
    shelf = Catalog::ForeignKey.new(
      name: "fk_books_shelf_id",
      columns: ["shelf_id"],
      references_table: "shelves",
      on_delete: "CASCADE",
    )
    table = Catalog::Table.new("books", [
      Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true),
      Catalog::Column.new("title", "text", false, nil),
      Catalog::Column.new("pages", "integer", false, "0"),
      Catalog::Column.new("subtitle", "text", true, "'untitled'"),
      Catalog::Column.new("shelf_id", "bigint", true, nil),
    ], foreign_keys: [shelf])
    DDL.create_table(table).should eq(<<-SQL)
      CREATE TABLE "books" (
        "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        "title" text NOT NULL,
        "pages" integer NOT NULL DEFAULT 0,
        "subtitle" text DEFAULT 'untitled',
        "shelf_id" bigint,
        CONSTRAINT "fk_books_shelf_id" FOREIGN KEY ("shelf_id") \
          REFERENCES "shelves" ("id") ON DELETE CASCADE
      )
      SQL
  end

  it "declares a composite primary key as a table constraint" do
    table = Catalog::Table.new("memberships", [
      Catalog::Column.new("team_id", "bigint", false, nil, primary: true),
      Catalog::Column.new("user_id", "bigint", false, nil, primary: true),
    ])
    DDL.create_table(table).should eq(<<-SQL)
      CREATE TABLE "memberships" (
        "team_id" bigint NOT NULL,
        "user_id" bigint NOT NULL,
        PRIMARY KEY ("team_id", "user_id")
      )
      SQL
  end

  it "builds indexes inline for new tables and concurrently and idempotently for existing ones" do
    columns = ["author", "title"]
    index = Catalog::Index.new("index_books_on_author_and_title", columns, unique: true)
    inline = %(CREATE UNIQUE INDEX "index_books_on_author_and_title" ) \
             %(ON "books" ("author", "title"))
    concurrent = %(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ) \
                 %("index_books_on_author_and_title" ON "books" ("author", "title"))
    dropped = %(DROP INDEX CONCURRENTLY IF EXISTS "index_books_on_isbn")
    add = Differ::AddIndex.new("books", index, concurrently: false)
    add_online = Differ::AddIndex.new("books", index, concurrently: true)
    drop = Differ::DropIndex.new("books", "index_books_on_isbn")
    DDL.render(add).should eq(inline)
    DDL.render(add_online).should eq(concurrent)
    DDL.render(drop).should eq(dropped)
  end

  it "marks only explicit renames and drops with the annotation the linter accepts" do
    rename = Differ::RenameColumn.new("teams", "email", "billing_email")
    explicit = Differ::DropColumn.new("teams", "legacy", explicit: true)
    implicit = Differ::DropColumn.new("teams", "legacy", explicit: false)
    renamed = %(-- caramel:allow-rename teams.email\n) \
              %(ALTER TABLE "teams" RENAME COLUMN "email" TO "billing_email")
    dropped = %(ALTER TABLE "teams" DROP COLUMN "legacy")
    DDL.render(rename).should eq(renamed)
    DDL.render(explicit).should eq(%(-- caramel:allow-drop teams.legacy\n#{dropped}))
    DDL.render(implicit).should eq(dropped)
  end

  it "renders column changes" do
    seats = Catalog::Column.new("seats", "integer", false, "5")
    added = %(ALTER TABLE "teams" ADD COLUMN "seats" integer NOT NULL DEFAULT 5)
    DDL.render(Differ::AddColumn.new("teams", seats)).should eq(added)

    alter = %(ALTER TABLE "teams" ALTER COLUMN "seats")
    nullable = Differ::AlterNull.new("teams", "seats", nullable: true)
    required = Differ::AlterNull.new("teams", "seats", nullable: false)
    defaulted = Differ::AlterDefault.new("teams", "seats", "10")
    undefaulted = Differ::AlterDefault.new("teams", "seats", nil)
    widened = Differ::AlterType.new("teams", "seats", "bigint")
    DDL.render(nullable).should eq("#{alter} DROP NOT NULL")
    DDL.render(required).should eq("#{alter} SET NOT NULL")
    DDL.render(defaulted).should eq("#{alter} SET DEFAULT 10")
    DDL.render(undefaulted).should eq("#{alter} DROP DEFAULT")
    DDL.render(widened).should eq(%(#{alter} TYPE bigint USING "seats"::bigint))
  end

  it "adds a foreign key without validating it, then validates it separately" do
    key = Catalog::ForeignKey.new(
      name: "fk_users_team_id",
      columns: ["team_id"],
      references_table: "teams",
      on_delete: "SET NULL",
    )
    add = Differ::AddForeignKey.new("users", key, not_valid: true)
    validate = Differ::ValidateConstraint.new("users", "fk_users_team_id")
    drop = Differ::DropForeignKey.new("users", "fk_users_team_id")
    added = %(ALTER TABLE "users" ADD CONSTRAINT "fk_users_team_id" ) \
            %(FOREIGN KEY ("team_id") REFERENCES "teams" ("id") ) \
            %(ON DELETE SET NULL NOT VALID)
    validated = %(ALTER TABLE "users" VALIDATE CONSTRAINT "fk_users_team_id")
    dropped = %(ALTER TABLE "users" DROP CONSTRAINT "fk_users_team_id")
    DDL.render(add).should eq(added)
    DDL.render(validate).should eq(validated)
    DDL.render(drop).should eq(dropped)
  end

  it "renders a composite foreign key with its columns in order" do
    author = Catalog::ForeignKey.new(
      name: "fk_books_author_id",
      columns: ["author_id", "account_id"],
      references_table: "authors",
      references_columns: ["id", "account_id"],
    )
    add = Differ::AddForeignKey.new("books", author, not_valid: false)
    added = %(ALTER TABLE "books" ADD CONSTRAINT "fk_books_author_id" ) \
            %(FOREIGN KEY ("author_id", "account_id") ) \
            %(REFERENCES "authors" ("id", "account_id"))
    DDL.render(add).should eq(added)
  end

  it "quotes identifiers and refuses an ON DELETE action outside PostgreSQL's set" do
    DDL.quote(%(odd"name)).should eq(%("odd""name"))
    injection = "CASCADE; DROP TABLE teams"
    key = Catalog::ForeignKey.new("fk", ["team_id"], "teams", on_delete: injection)
    add = Differ::AddForeignKey.new("users", key, not_valid: true)
    expect_raises(ArgumentError, "unsupported ON DELETE") { DDL.render(add) }
  end

  it "adds a check without validating it, and renders a range or its SQL verbatim" do
    range = Catalog::Check.new("check_books_copies", column: "copies", min: 0_i64, max: 10_i64)
    sql = "starts_at < ends_at"
    dates = Catalog::Check.new("check_books_dates", expression: sql)
    added = %(ALTER TABLE "books" ADD CONSTRAINT "check_books_copies" ) \
            %(CHECK ("copies" >= 0 AND "copies" <= 10) NOT VALID)
    verbatim = %(ALTER TABLE "books" ADD CONSTRAINT "check_books_dates" ) \
               %(CHECK (starts_at < ends_at))
    dropped = %(ALTER TABLE "books" DROP CONSTRAINT "check_books_copies")
    DDL.render(Differ::AddCheck.new("books", range, not_valid: true)).should eq(added)
    DDL.render(Differ::AddCheck.new("books", dates, not_valid: false)).should eq(verbatim)
    DDL.render(Differ::DropCheck.new("books", "check_books_copies")).should eq(dropped)
  end

  it "renders an open-ended range with its one bound and refuses an empty check" do
    lower = Catalog::Check.new("check_books_copies", column: "copies", min: 1_i64)
    upper = Catalog::Check.new("check_books_limit", column: "limit", max: 5_i64)
    DDL.check_constraint(lower).should eq(%(CONSTRAINT "check_books_copies" CHECK ("copies" >= 1)))
    DDL.check_constraint(upper).should eq(%(CONSTRAINT "check_books_limit" CHECK ("limit" <= 5)))
    expect_raises(ArgumentError, "check check_books_none has neither a column nor an expression") do
      DDL.check_constraint(Catalog::Check.new("check_books_none"))
    end
  end

  it "creates a table with its checks inline" do
    table = Catalog::Table.new("books", [
      Catalog::Column.new("copies", "integer", false, nil),
    ], checks: [Catalog::Check.new("check_books_copies", column: "copies", min: 1_i64)])
    DDL.create_table(table).should eq(<<-SQL)
      CREATE TABLE "books" (
        "copies" integer NOT NULL,
        CONSTRAINT "check_books_copies" CHECK ("copies" >= 1)
      )
      SQL
  end
end
