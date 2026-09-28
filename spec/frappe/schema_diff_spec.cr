require "spec"
require "../../src/frappe/schema_diff"

private def migration_source(sql : String) : String
  Caramel::Frappe::SchemaDiff.source(SugarORM::Migration.new(20260928000001_i64, "probe", [sql]))
end

describe Caramel::Frappe::SchemaDiff do
  # An unquoted heredoc would interpolate `#{…}` and decode escapes such as
  # `\n`, so the compiled migration would differ from the derived SQL.
  it "quotes a migration's SQL heredoc exactly when interpolation or escapes must stay literal" do
    migration_source(%(CREATE TABLE "notes" ("body" text NOT NULL))).should contain(%(  <<-SQL,\n    CREATE TABLE "notes"))
    migration_source(%(ALTER TABLE "notes" ALTER COLUMN "body" SET DEFAULT E'a\\nb')).should contain(%(  <<-'SQL',\n    ALTER TABLE "notes" ALTER COLUMN "body" SET DEFAULT E'a\\nb'\n))
    migration_source(%(COMMENT ON TABLE "notes" IS '\#{title}')).should contain(%(  <<-'SQL',\n    COMMENT ON TABLE "notes" IS '\#{title}'\n))
  end
end
