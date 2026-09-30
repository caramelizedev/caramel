require "spec"
require "../../src/frappe/schema_diff"

private def migration_source(sql : String) : String
  Caramel::Frappe::SchemaDiff.source(SugarORM::Migration.new(20260928000001_i64, "probe", [sql]))
end

describe Caramel::Frappe::SchemaDiff do
  # An unquoted heredoc would interpolate `#{…}` and decode escapes such as
  # `\n`, so the compiled migration would differ from the derived SQL.
  it "quotes a migration's SQL heredoc exactly when interpolation or escapes must stay literal" do
    plain = %(CREATE TABLE "notes" ("body" text NOT NULL))
    migration_source(plain).should contain(%(  <<-SQL,\n    CREATE TABLE "notes"))
    escape = %(ALTER TABLE "notes" ALTER COLUMN "body" SET DEFAULT E'a\\nb')
    migration_source(escape).should contain("  <<-'SQL',\n    #{escape}\n")
    interpolation = %(COMMENT ON TABLE "notes" IS '\#{title}')
    migration_source(interpolation).should contain("  <<-'SQL',\n    #{interpolation}\n")
    # A backslash that is no escape sequence still stays literal; Ameba would
    # ask for an unquoted heredoc, which would drop it.
    lone = migration_source(%(ALTER TABLE "notes" ALTER COLUMN "path" SET DEFAULT 'a\\_b'))
    disable = "  # ameba:disable Style/HeredocEscape -- its backslashes stay literal\n"
    lone.should contain("#{disable}  <<-'SQL',\n")
    migration_source(escape).should_not contain("ameba:disable")
  end
end
