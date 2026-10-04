require "db"
require "json"
require "./catalog"

module SugarORM
  module Catalog
    # The document a compiled application's `schema` command prints for Frappé.
    def self.to_json(tables : Array(Table)) : String
      JSON.build do |json|
        json.object do
          json.field "version", 2
          json.field "tables" do
            json.array do
              tables.each do |table|
                json.object do
                  json.field "name", table.name
                  json.field "columns" do
                    json.array do
                      table.columns.each do |column|
                        json.object do
                          json.field "name", column.name
                          json.field "sql_type", column.sql_type
                          json.field "nullable", column.nullable
                          json.field "default", column.default
                          json.field "primary", column.primary
                          json.field "identity", column.identity
                          json.field "renamed_from", column.renamed_from
                        end
                      end
                    end
                  end
                  json.field "indexes" do
                    json.array do
                      table.indexes.each do |index|
                        json.object do
                          json.field "name", index.name
                          json.field "columns", index.columns
                          json.field "unique", index.unique
                        end
                      end
                    end
                  end
                  json.field "foreign_keys" do
                    json.array do
                      table.foreign_keys.each do |key|
                        json.object do
                          json.field "name", key.name
                          json.field "columns", key.columns
                          json.field "references_table", key.references_table
                          json.field "references_columns", key.references_columns
                          json.field "on_delete", key.on_delete
                        end
                      end
                    end
                  end
                  json.field "drops", table.drops
                end
              end
            end
          end
        end
      end
    end

    def self.from_json(text : String) : Array(Table)
      document = JSON.parse(text)
      version = document["version"].as_i
      raise ArgumentError.new("unsupported schema document version") unless version == 2
      document["tables"].as_a.map do |table|
        columns = table["columns"].as_a.map do |column|
          Column.new(
            name: column["name"].as_s,
            sql_type: column["sql_type"].as_s,
            nullable: column["nullable"].as_bool,
            default: column["default"].as_s?,
            primary: column["primary"].as_bool,
            identity: column["identity"].as_bool,
            renamed_from: column["renamed_from"].as_s?,
          )
        end
        indexes = table["indexes"].as_a.map do |index|
          Index.new(
            name: index["name"].as_s,
            columns: index["columns"].as_a.map(&.as_s),
            unique: index["unique"].as_bool,
          )
        end
        foreign_keys = table["foreign_keys"].as_a.map do |key|
          ForeignKey.new(
            name: key["name"].as_s,
            columns: key["columns"].as_a.map(&.as_s),
            references_table: key["references_table"].as_s,
            references_columns: key["references_columns"].as_a.map(&.as_s),
            on_delete: key["on_delete"].as_s,
          )
        end
        Table.new(
          name: table["name"].as_s,
          columns: columns,
          indexes: indexes,
          foreign_keys: foreign_keys,
          drops: table["drops"].as_a.map(&.as_s),
        )
      end
    rescue ex : JSON::ParseException | KeyError | TypeCastError
      raise ArgumentError.new("invalid schema document: #{ex.message}")
    end
  end

  # Reads the live catalog of the current schema from pg_catalog. Values are
  # normalized so that a table created from a declared Catalog::Table reads
  # back equal to it; indexes and foreign keys are ordered by name.
  module Introspection
    record Snapshot,
      tables : Array(Catalog::Table),
      invalid_indexes : Array(String) = [] of String,
      skipped : Array(String) = [] of String

    ON_DELETE = {
      "a" => "NO ACTION",
      "r" => "RESTRICT",
      "c" => "CASCADE",
      "n" => "SET NULL",
      "d" => "SET DEFAULT",
    }
    NUMERIC = {"integer", "bigint", "smallint", "double precision", "real", "numeric"}

    # A plain or scientific decimal number, as a numeric default is spelled.
    NUMBER_LITERAL = /\A-?\d+(?:\.\d+)?(?:e[+-]?\d+)?\z/i

    TABLES = <<-SQL
      SELECT c.relname::text
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p')
      ORDER BY 1
      SQL

    COLUMNS = <<-SQL
      SELECT c.relname::text, a.attname::text, format_type(a.atttypid, a.atttypmod), a.attnotnull,
             CASE WHEN a.attgenerated = '' THEN pg_get_expr(d.adbin, d.adrelid) END,
             a.attidentity IN ('a', 'd'),
             EXISTS (SELECT 1 FROM pg_index x WHERE x.indrelid = a.attrelid \
                       AND x.indisprimary AND a.attnum = ANY (x.indkey))
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') \
        AND a.attnum > 0 AND NOT a.attisdropped
      ORDER BY c.relname, a.attnum
      SQL

    INDEXES = <<-SQL
      SELECT t.relname::text, i.relname::text, x.indisunique, x.indisvalid,
             x.indexprs IS NOT NULL OR x.indpred IS NOT NULL
               OR EXISTS (SELECT 1 FROM pg_constraint con \
                 WHERE con.conindid = x.indexrelid AND con.contype IN ('p', 'u', 'x')),
             ARRAY(SELECT a.attname::text
                   FROM unnest(x.indkey::int2[]) WITH ORDINALITY AS k(attnum, position)
                   JOIN pg_attribute a ON a.attrelid = x.indrelid AND a.attnum = k.attnum
                   WHERE k.position <= x.indnkeyatts
                   ORDER BY k.position)
      FROM pg_index x
      JOIN pg_class i ON i.oid = x.indexrelid
      JOIN pg_class t ON t.oid = x.indrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE n.nspname = current_schema() AND t.relkind IN ('r', 'p') AND NOT x.indisprimary
      ORDER BY 1, 2
      SQL

    FOREIGN_KEYS = <<-SQL
      SELECT t.relname::text, con.conname::text,
             ARRAY(SELECT a.attname::text
                   FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, position)
                   JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
                   ORDER BY k.position),
             r.relname::text,
             ARRAY(SELECT a.attname::text
                   FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, position)
                   JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum
                   ORDER BY k.position),
             con.confdeltype::text
      FROM pg_constraint con
      JOIN pg_class t ON t.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      JOIN pg_class r ON r.oid = con.confrelid
      WHERE con.contype = 'f' AND n.nspname = current_schema()
      ORDER BY 1, 2
      SQL

    COLUMN_ROW      = {String, String, String, Bool, String?, Bool, Bool}
    INDEX_ROW       = {String, String, Bool, Bool, Bool, Array(String)}
    FOREIGN_KEY_ROW = {String, String, Array(String), String, Array(String), String}

    def self.read(db : DB::Database | DB::Connection) : Snapshot
      invalid, skipped = [] of String, [] of String
      columns = read_columns(db)
      indexes = read_indexes(db, invalid, skipped)
      keys = read_foreign_keys(db)
      tables = db.query_all(TABLES, as: String).map do |table|
        Catalog::Table.new(
          name: table,
          columns: columns.fetch(table) { [] of Catalog::Column },
          indexes: indexes.fetch(table) { [] of Catalog::Index },
          foreign_keys: keys.fetch(table) { [] of Catalog::ForeignKey },
        )
      end
      Snapshot.new(tables, invalid, skipped)
    end

    # pg_get_expr spells constants with casts ('x'::text, '-5'::integer, and
    # '-3'::integer in a bigint column); declared defaults are bare SQL
    # literals ('x', -5, 2.5, true).
    def self.normalize_default(expression : String?, sql_type : String) : String?
      return unless expression
      return "CURRENT_TIMESTAMP" if expression == "now()"
      if match = expression.match(/\A'((?:[^']|'')*)'::(.+)\z/)
        literal, type = match[1], match[2]
        numeric = NUMERIC.includes?(sql_type) && NUMERIC.includes?(type)
        return literal if numeric && literal.matches?(NUMBER_LITERAL)
        return expression unless type == sql_type
        return literal if sql_type == "boolean" && {"true", "false"}.includes?(literal)
        return "'#{literal}'"
      end
      expression
    end

    # The columns of each table, in attribute order.
    private def self.read_columns(db : DB::Database | DB::Connection)
      columns = by_table(Catalog::Column)
      rows = db.query_all(COLUMNS, as: COLUMN_ROW)
      rows.each do |table, name, type, not_null, default, identity, primary|
        columns[table] << Catalog::Column.new(
          name: name,
          sql_type: type,
          nullable: !not_null,
          default: identity ? nil : normalize_default(default, type),
          primary: primary,
          identity: identity,
        )
      end
      columns
    end

    # Valid plain indexes by table; an invalid index, or one the differ cannot
    # compare, is reported instead.
    private def self.read_indexes(db : DB::Database | DB::Connection,
                                  invalid : Array(String),
                                  skipped : Array(String))
      indexes = by_table(Catalog::Index)
      rows = db.query_all(INDEXES, as: INDEX_ROW)
      rows.each do |table, name, unique, valid, special, names|
        if !valid
          invalid << name
        elsif special
          # The differ ignores Caramel-owned tables whole, indexes included.
          next if table.starts_with?("caramel_")
          skipped << "skipped index #{name} on #{table} " \
                     "(expression, partial or constraint index)"
        else
          indexes[table] << Catalog::Index.new(name, names, unique)
        end
      end
      indexes
    end

    # Foreign keys by table, each with its columns in key order.
    private def self.read_foreign_keys(db : DB::Database | DB::Connection)
      keys = by_table(Catalog::ForeignKey)
      rows = db.query_all(FOREIGN_KEYS, as: FOREIGN_KEY_ROW)
      rows.each do |table, name, columns, target, target_columns, action|
        keys[table] << Catalog::ForeignKey.new(
          name: name,
          columns: columns,
          references_table: target,
          references_columns: target_columns,
          on_delete: ON_DELETE[action],
        )
      end
      keys
    end

    # A hash that starts an empty list for each table on first use.
    private def self.by_table(type : T.class) : Hash(String, Array(T)) forall T
      Hash(String, Array(T)).new { |hash, table| hash[table] = [] of T }
    end
  end
end
