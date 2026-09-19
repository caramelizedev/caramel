module Bookshelf
  MIGRATIONS = [Caramel::Migration.new(20260919000001_i64, "Create books", [<<-SQL])]
    CREATE TABLE books (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      title varchar(200) NOT NULL CHECK (length(trim(title)) > 0),
      author varchar(200) NOT NULL CHECK (length(trim(author)) > 0),
      created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
      updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
    SQL
end
