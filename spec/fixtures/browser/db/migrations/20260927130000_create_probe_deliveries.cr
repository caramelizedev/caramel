App::MIGRATIONS << SugarORM::Migration.new(20260927130000_i64, "create_probe_deliveries", [
  <<-'SQL',
    CREATE TABLE probe_deliveries (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      board_id bigint NOT NULL,
      delivered_at timestamptz
    )
    SQL
])
