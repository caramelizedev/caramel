require "spec"
require "../../src/sugar_orm/ddl"

private alias Catalog = SugarORM::Catalog
private alias Differ = SugarORM::Differ
private alias DDL = SugarORM::DDL

describe SugarORM::DDL do
  it "renders a table with an identity key, defaults, nullability and inline foreign keys" do
    table = Catalog::Table.new("books", [
      Catalog::Column.new("id", "bigint", false, nil, primary: true, identity: true),
      Catalog::Column.new("title", "text", false, nil),
      Catalog::Column.new("pages", "integer", false, "0"),
      Catalog::Column.new("subtitle", "text", true, "'untitled'"),
      Catalog::Column.new("shelf_id", "bigint", true, nil),
    ], foreign_keys: [Catalog::ForeignKey.new("fk_books_shelf_id", "shelf_id", "shelves", on_delete: "CASCADE")])
    DDL.create_table(table).should eq(<<-SQL)
      CREATE TABLE "books" (
        "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        "title" text NOT NULL,
        "pages" integer NOT NULL DEFAULT 0,
        "subtitle" text DEFAULT 'untitled',
        "shelf_id" bigint,
        CONSTRAINT "fk_books_shelf_id" FOREIGN KEY ("shelf_id") REFERENCES "shelves" ("id") ON DELETE CASCADE
      )
      SQL
  end

  it "declares a composite primary key as a table constraint" do
    table = Catalog::Table.new("memberships", [
      Catalog::Column.new("team_id", "bigint", false, nil, primary: true),
      Catalog::Column.new("user_id", "bigint", false, nil, primary: true),
    ])
    DDL.create_table(table).should eq(%(CREATE TABLE "memberships" (\n  "team_id" bigint NOT NULL,\n  "user_id" bigint NOT NULL,\n  PRIMARY KEY ("team_id", "user_id")\n)))
  end

  it "builds indexes inline for new tables and concurrently and idempotently for existing ones" do
    index = Catalog::Index.new("index_books_on_author_and_title", ["author", "title"], unique: true)
    DDL.render(Differ::AddIndex.new("books", index, concurrently: false)).should eq(%(CREATE UNIQUE INDEX "index_books_on_author_and_title" ON "books" ("author", "title")))
    DDL.render(Differ::AddIndex.new("books", index, concurrently: true)).should eq(%(CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS "index_books_on_author_and_title" ON "books" ("author", "title")))
    DDL.render(Differ::DropIndex.new("books", "index_books_on_isbn")).should eq(%(DROP INDEX CONCURRENTLY IF EXISTS "index_books_on_isbn"))
  end

  it "marks only explicit renames and drops with the annotation the linter accepts" do
    DDL.render(Differ::RenameColumn.new("teams", "email", "billing_email")).should eq(%(-- caramel:allow-rename teams.email\nALTER TABLE "teams" RENAME COLUMN "email" TO "billing_email"))
    DDL.render(Differ::DropColumn.new("teams", "legacy", explicit: true)).should eq(%(-- caramel:allow-drop teams.legacy\nALTER TABLE "teams" DROP COLUMN "legacy"))
    DDL.render(Differ::DropColumn.new("teams", "legacy", explicit: false)).should eq(%(ALTER TABLE "teams" DROP COLUMN "legacy"))
  end

  it "renders column changes" do
    DDL.render(Differ::AddColumn.new("teams", Catalog::Column.new("seats", "integer", false, "5"))).should eq(%(ALTER TABLE "teams" ADD COLUMN "seats" integer NOT NULL DEFAULT 5))
    DDL.render(Differ::AlterNull.new("teams", "seats", nullable: true)).should eq(%(ALTER TABLE "teams" ALTER COLUMN "seats" DROP NOT NULL))
    DDL.render(Differ::AlterNull.new("teams", "seats", nullable: false)).should eq(%(ALTER TABLE "teams" ALTER COLUMN "seats" SET NOT NULL))
    DDL.render(Differ::AlterDefault.new("teams", "seats", "10")).should eq(%(ALTER TABLE "teams" ALTER COLUMN "seats" SET DEFAULT 10))
    DDL.render(Differ::AlterDefault.new("teams", "seats", nil)).should eq(%(ALTER TABLE "teams" ALTER COLUMN "seats" DROP DEFAULT))
    DDL.render(Differ::AlterType.new("teams", "seats", "bigint")).should eq(%(ALTER TABLE "teams" ALTER COLUMN "seats" TYPE bigint USING "seats"::bigint))
  end

  it "adds a foreign key without validating it, then validates it separately" do
    key = Catalog::ForeignKey.new("fk_users_team_id", "team_id", "teams", on_delete: "SET NULL")
    DDL.render(Differ::AddForeignKey.new("users", key, not_valid: true)).should eq(%(ALTER TABLE "users" ADD CONSTRAINT "fk_users_team_id" FOREIGN KEY ("team_id") REFERENCES "teams" ("id") ON DELETE SET NULL NOT VALID))
    DDL.render(Differ::ValidateForeignKey.new("users", "fk_users_team_id")).should eq(%(ALTER TABLE "users" VALIDATE CONSTRAINT "fk_users_team_id"))
    DDL.render(Differ::DropForeignKey.new("users", "fk_users_team_id")).should eq(%(ALTER TABLE "users" DROP CONSTRAINT "fk_users_team_id"))
  end

  it "quotes identifiers and refuses an ON DELETE action outside PostgreSQL's set" do
    DDL.quote(%(odd"name)).should eq(%("odd""name"))
    key = Catalog::ForeignKey.new("fk", "team_id", "teams", on_delete: "CASCADE; DROP TABLE teams")
    expect_raises(ArgumentError, "unsupported ON DELETE") { DDL.render(Differ::AddForeignKey.new("users", key, not_valid: true)) }
  end
end
