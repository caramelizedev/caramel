require "./differ"

module SugarORM
  # Renders differ operations as PostgreSQL statements, one per operation.
  # Explicit rename and drop intents carry the annotation the linter accepts.
  module DDL
    ON_DELETE = {"NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"}

    # What a date column prints under an ISO DateStyle, as a pattern for a text column.
    DAY_TEXT   = "'^[0-9]{4}-[0-9]{2}-[0-9]{2}$'"
    OLD_SERVER = "retyping % from text to date needs PostgreSQL 16 or newer"
    NOT_DAYS   = "% holds % rows that are not days written YYYY-MM-DD; first distinct values: %"

    def self.quote(identifier : String) : String
      %("#{identifier.gsub('"', "\"\"")}")
    end

    # *identifiers*, each quoted, joined as a column list.
    def self.quote_list(identifiers : Array(String)) : String
      identifiers.join(", ") { |identifier| quote(identifier) }
    end

    def self.statements(operations : Array(Differ::Operation)) : Array(String)
      operations.map { |operation| render(operation) }
    end

    def self.create_table(table : Catalog::Table) : String
      primary = table.columns.select(&.primary)
      inline = primary.size == 1
      lines = table.columns.map do |column|
        column_definition(column, inline_primary: inline)
      end
      if primary.size > 1
        keys = primary.join(", ") { |column| quote(column.name) }
        lines << "PRIMARY KEY (#{keys})"
      end
      table.foreign_keys.each { |key| lines << constraint(key) }
      table.checks.each { |check| lines << check_constraint(check) }
      body = lines.join(",\n") { |line| "  #{line}" }
      "CREATE TABLE #{quote(table.name)} (\n#{body}\n)"
    end

    def self.column_definition(column : Catalog::Column,
                               inline_primary : Bool = true) : String
      String.build do |sql|
        sql << quote(column.name) << ' ' << column.sql_type
        if column.identity
          sql << " GENERATED ALWAYS AS IDENTITY"
        else
          sql << " NOT NULL" unless column.nullable
          column.default.try { |default| sql << " DEFAULT " << default }
        end
        sql << " PRIMARY KEY" if column.primary && inline_primary
      end
    end

    def self.render(operation : Differ::CreateTable) : String
      create_table(operation.table)
    end

    def self.render(operation : Differ::AddColumn) : String
      definition = column_definition(operation.column)
      "ALTER TABLE #{quote(operation.table)} ADD COLUMN #{definition}"
    end

    def self.render(operation : Differ::RenameColumn) : String
      from = quote(operation.from)
      to = quote(operation.to)
      "-- caramel:allow-rename #{operation.table}.#{operation.from}\n" \
      "ALTER TABLE #{quote(operation.table)} RENAME COLUMN #{from} TO #{to}"
    end

    def self.render(operation : Differ::DropColumn) : String
      sql = "ALTER TABLE #{quote(operation.table)} DROP COLUMN #{quote(operation.column)}"
      return sql unless operation.explicit
      "-- caramel:allow-drop #{operation.table}.#{operation.column}\n#{sql}"
    end

    def self.render(operation : Differ::AlterNull) : String
      change = operation.nullable ? "DROP" : "SET"
      "#{alter_column(operation.table, operation.column)} #{change} NOT NULL"
    end

    def self.render(operation : Differ::AlterDefault) : String
      change = operation.default.try { |default| "SET DEFAULT #{default}" } || "DROP DEFAULT"
      "#{alter_column(operation.table, operation.column)} #{change}"
    end

    def self.render(operation : Differ::AlterType) : String
      alter = alter_column(operation.table, operation.column)
      column = quote(operation.column)
      type = operation.sql_type
      "#{alter} TYPE #{type} USING #{column}::#{type}"
    end

    # A DO block, because the check must read the rows. It locks the table first, so no row
    # arrives between the check and the retype. A value passes when it is written
    # YYYY-MM-DD and PostgreSQL (16 and later: pg_input_is_valid) accepts it as a day.
    # The message counts the rows and shows up to five distinct values, cut to 40 characters.
    def self.render(operation : Differ::AssertDateText) : String
      table = quote(operation.table)
      column = quote(operation.column)
      subject = "#{operation.table}.#{operation.column}".gsub("'", "''")
      <<-SQL
        DO $caramel$
        DECLARE
          counted bigint;
          samples text;
        BEGIN
          IF current_setting('server_version_num')::int < 160000 THEN
            RAISE EXCEPTION '#{OLD_SERVER}', '#{subject}';
          END IF;
          LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE;
          WITH refused AS (
            SELECT #{column} AS value FROM #{table}
            WHERE #{column} IS NOT NULL
              AND NOT (#{column} ~ #{DAY_TEXT}
                       AND pg_input_is_valid(#{column}, 'date'))
          )
          SELECT (SELECT count(*) FROM refused),
                 (SELECT string_agg(sample, ', ' ORDER BY sample) FROM (
                    SELECT DISTINCT format('%L', left(value, 40)) AS sample
                    FROM refused ORDER BY 1 LIMIT 5) AS offending)
          INTO counted, samples;
          IF counted > 0 THEN
            RAISE EXCEPTION '#{NOT_DAYS}', '#{subject}', counted, samples
              USING ERRCODE = '22007';
          END IF;
        END
        $caramel$
        SQL
    end

    # Online builds are idempotent so an interrupted autocommit migration can
    # be retried; the migrator refuses an INVALID index left under the name.
    def self.render(operation : Differ::AddIndex) : String
      index = operation.index
      String.build do |sql|
        sql << "CREATE " << (index.unique ? "UNIQUE INDEX " : "INDEX ")
        sql << "CONCURRENTLY IF NOT EXISTS " if operation.concurrently
        sql << quote(index.name) << " ON " << quote(operation.table)
        sql << " (" << index.columns.join(", ") { |column| quote(column) } << ')'
      end
    end

    def self.render(operation : Differ::DropIndex) : String
      "DROP INDEX CONCURRENTLY IF EXISTS #{quote(operation.name)}"
    end

    def self.render(operation : Differ::RenameIndex) : String
      "ALTER INDEX #{quote(operation.from)} RENAME TO #{quote(operation.to)}"
    end

    def self.render(operation : Differ::AddForeignKey) : String
      table = quote(operation.table)
      sql = "ALTER TABLE #{table} ADD #{constraint(operation.foreign_key)}"
      operation.not_valid ? "#{sql} NOT VALID" : sql
    end

    def self.render(operation : Differ::ValidateConstraint) : String
      "ALTER TABLE #{quote(operation.table)} VALIDATE CONSTRAINT #{quote(operation.name)}"
    end

    def self.render(operation : Differ::AddCheck) : String
      sql = "ALTER TABLE #{quote(operation.table)} ADD #{check_constraint(operation.check)}"
      operation.not_valid ? "#{sql} NOT VALID" : sql
    end

    def self.render(operation : Differ::DropCheck) : String
      "ALTER TABLE #{quote(operation.table)} DROP CONSTRAINT #{quote(operation.name)}"
    end

    def self.render(operation : Differ::DropForeignKey) : String
      "ALTER TABLE #{quote(operation.table)} DROP CONSTRAINT #{quote(operation.name)}"
    end

    # `CONSTRAINT "name" CHECK (…)`: the declared SQL, or the bounds of a range.
    def self.check_constraint(check : Catalog::Check) : String
      "CONSTRAINT #{quote(check.name)} CHECK (#{check_expression(check)})"
    end

    # The start of a statement that changes `column` of `table`.
    private def self.alter_column(table : String, column : String) : String
      "ALTER TABLE #{quote(table)} ALTER COLUMN #{quote(column)}"
    end

    private def self.constraint(key : Catalog::ForeignKey) : String
      "CONSTRAINT #{quote(key.name)} #{references(key)}"
    end

    private def self.check_expression(check : Catalog::Check) : String
      check.expression || range_expression(check)
    end

    private def self.range_expression(check : Catalog::Check) : String
      column = check.column
      unless column
        raise ArgumentError.new("check #{check.name} has neither a column nor an expression")
      end
      bounds = [] of String
      check.min.try { |min| bounds << "#{quote(column)} >= #{min}" }
      check.max.try { |max| bounds << "#{quote(column)} <= #{max}" }
      bounds.join(" AND ")
    end

    private def self.references(key : Catalog::ForeignKey) : String
      action = key.on_delete
      unless ON_DELETE.includes?(action)
        raise ArgumentError.new("unsupported ON DELETE action: #{action}")
      end
      targets = quote_list(key.references_columns)
      target = "#{quote(key.references_table)} (#{targets})"
      clause = "FOREIGN KEY (#{quote_list(key.columns)}) REFERENCES #{target}"
      action == "NO ACTION" ? clause : "#{clause} ON DELETE #{action}"
    end
  end
end
