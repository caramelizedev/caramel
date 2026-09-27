require "db"
require "json"
require "./catalog"

module SugarORM
  module Catalog
    # The document a compiled application's `schema` command prints for Frappé.
    def self.to_json(tables : Array(Table)) : String
      JSON.build do |json|
        json.object do
          json.field "version", 1
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
                          json.field "column", key.column
                          json.field "references_table", key.references_table
                          json.field "references_column", key.references_column
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
      raise ArgumentError.new("unsupported schema document version") unless document["version"].as_i == 1
      document["tables"].as_a.map do |table|
        Table.new(
          table["name"].as_s,
          table["columns"].as_a.map { |column|
            Column.new(column["name"].as_s, column["sql_type"].as_s, column["nullable"].as_bool, column["default"].as_s?,
              column["primary"].as_bool, column["identity"].as_bool, column["renamed_from"].as_s?)
          },
          table["indexes"].as_a.map { |index| Index.new(index["name"].as_s, index["columns"].as_a.map(&.as_s), index["unique"].as_bool) },
          table["foreign_keys"].as_a.map { |key|
            ForeignKey.new(key["name"].as_s, key["column"].as_s, key["references_table"].as_s, key["references_column"].as_s, key["on_delete"].as_s)
          },
          table["drops"].as_a.map(&.as_s),
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
    record Snapshot, tables : Array(Catalog::Table), invalid_indexes : Array(String) = [] of String, skipped : Array(String) = [] of String

    ON_DELETE = {"a" => "NO ACTION", "r" => "RESTRICT", "c" => "CASCADE", "n" => "SET NULL", "d" => "SET DEFAULT"}
    NUMERIC   = {"integer", "bigint", "smallint", "double precision", "real", "numeric"}

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
             EXISTS (SELECT 1 FROM pg_index x WHERE x.indrelid = a.attrelid AND x.indisprimary AND a.attnum = ANY (x.indkey))
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
      ORDER BY c.relname, a.attnum
      SQL

    INDEXES = <<-SQL
      SELECT t.relname::text, i.relname::text, x.indisunique, x.indisvalid,
             x.indexprs IS NOT NULL OR x.indpred IS NOT NULL
               OR EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conindid = x.indexrelid AND con.contype IN ('p', 'u', 'x')),
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
      SELECT t.relname::text, con.conname::text, cardinality(con.conkey), a.attname::text,
             r.relname::text, ra.attname::text, con.confdeltype::text
      FROM pg_constraint con
      JOIN pg_class t ON t.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      JOIN pg_class r ON r.oid = con.confrelid
      JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
      JOIN pg_attribute ra ON ra.attrelid = con.confrelid AND ra.attnum = con.confkey[1]
      WHERE con.contype = 'f' AND n.nspname = current_schema()
      ORDER BY 1, 2
      SQL

    def self.read(db : DB::Database | DB::Connection) : Snapshot
      columns = Hash(String, Array(Catalog::Column)).new { |hash, key| hash[key] = [] of Catalog::Column }
      indexes = Hash(String, Array(Catalog::Index)).new { |hash, key| hash[key] = [] of Catalog::Index }
      keys = Hash(String, Array(Catalog::ForeignKey)).new { |hash, key| hash[key] = [] of Catalog::ForeignKey }
      invalid, skipped = [] of String, [] of String

      db.query_all(COLUMNS, as: {String, String, String, Bool, String?, Bool, Bool}).each do |table, name, type, not_null, default, identity, primary|
        columns[table] << Catalog::Column.new(name, type, !not_null, identity ? nil : normalize_default(default, type), primary, identity)
      end
      db.query_all(INDEXES, as: {String, String, Bool, Bool, Bool, Array(String)}).each do |table, name, unique, valid, special, names|
        if !valid
          invalid << name
        elsif special
          skipped << "skipped index #{name} on #{table} (expression, partial or constraint index)"
        else
          indexes[table] << Catalog::Index.new(name, names, unique)
        end
      end
      db.query_all(FOREIGN_KEYS, as: {String, String, Int32, String, String, String, String}).each do |table, name, size, column, target, target_column, action|
        if size == 1
          keys[table] << Catalog::ForeignKey.new(name, column, target, target_column, ON_DELETE[action])
        else
          skipped << "skipped foreign key #{name} on #{table} (multi-column)"
        end
      end
      tables = db.query_all(TABLES, as: String).map do |table|
        Catalog::Table.new(table, columns.fetch(table) { [] of Catalog::Column }, indexes.fetch(table) { [] of Catalog::Index }, keys.fetch(table) { [] of Catalog::ForeignKey })
      end
      Snapshot.new(tables, invalid, skipped)
    end

    # pg_get_expr spells constants with casts ('x'::text, '-5'::integer, and
    # '-3'::integer in a bigint column); declared defaults are bare SQL
    # literals ('x', -5, 2.5, true).
    def self.normalize_default(expression : String?, sql_type : String) : String?
      return nil unless expression
      return "CURRENT_TIMESTAMP" if expression == "now()"
      if match = expression.match(/\A'((?:[^']|'')*)'::(.+)\z/)
        literal, type = match[1], match[2]
        if NUMERIC.includes?(sql_type) && NUMERIC.includes?(type) && literal.matches?(/\A-?\d+(?:\.\d+)?(?:e[+-]?\d+)?\z/i)
          return literal
        end
        return expression unless type == sql_type
        return literal if sql_type == "boolean" && {"true", "false"}.includes?(literal)
        return "'#{literal}'"
      end
      expression
    end
  end
end
