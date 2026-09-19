App::MIGRATIONS << Caramel::Migration.new(@@VERSION@@_i64, "Create @@PLURAL@@", [<<-SQL])
  CREATE TABLE "@@PLURAL@@" (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
@@SQL_FIELDS@@
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
  )
  SQL
