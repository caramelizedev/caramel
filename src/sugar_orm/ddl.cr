require "./differ"

module SugarORM
  # Renders differ operations as PostgreSQL statements, one per operation.
  # Explicit rename and drop intents carry the annotation the linter accepts.
  module DDL
    ON_DELETE = {"NO ACTION", "RESTRICT", "CASCADE", "SET NULL", "SET DEFAULT"}

    def self.quote(identifier : String) : String
      %("#{identifier.gsub('"', "\"\"")}")
    end

    def self.statements(operations : Array(Differ::Operation)) : Array(String)
      operations.map { |operation| render(operation) }
    end

    def self.create_table(table : Catalog::Table) : String
      primary = table.columns.select(&.primary)
      lines = table.columns.map { |column| column_definition(column, inline_primary: primary.size == 1) }
      lines << "PRIMARY KEY (#{primary.join(", ") { |column| quote(column.name) }})" if primary.size > 1
      table.foreign_keys.each { |key| lines << "CONSTRAINT #{quote(key.name)} #{references(key)}" }
      "CREATE TABLE #{quote(table.name)} (\n#{lines.join(",\n") { |line| "  #{line}" }}\n)"
    end

    def self.column_definition(column : Catalog::Column, inline_primary : Bool = true) : String
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
      "ALTER TABLE #{quote(operation.table)} ADD COLUMN #{column_definition(operation.column)}"
    end

    def self.render(operation : Differ::RenameColumn) : String
      "-- caramel:allow-rename #{operation.table}.#{operation.from}\n" \
      "ALTER TABLE #{quote(operation.table)} RENAME COLUMN #{quote(operation.from)} TO #{quote(operation.to)}"
    end

    def self.render(operation : Differ::DropColumn) : String
      sql = "ALTER TABLE #{quote(operation.table)} DROP COLUMN #{quote(operation.column)}"
      operation.explicit ? "-- caramel:allow-drop #{operation.table}.#{operation.column}\n#{sql}" : sql
    end

    def self.render(operation : Differ::AlterNull) : String
      "ALTER TABLE #{quote(operation.table)} ALTER COLUMN #{quote(operation.column)} #{operation.nullable ? "DROP" : "SET"} NOT NULL"
    end

    def self.render(operation : Differ::AlterDefault) : String
      change = operation.default.try { |default| "SET DEFAULT #{default}" } || "DROP DEFAULT"
      "ALTER TABLE #{quote(operation.table)} ALTER COLUMN #{quote(operation.column)} #{change}"
    end

    def self.render(operation : Differ::AlterType) : String
      column = quote(operation.column)
      "ALTER TABLE #{quote(operation.table)} ALTER COLUMN #{column} TYPE #{operation.sql_type} USING #{column}::#{operation.sql_type}"
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

    def self.render(operation : Differ::AddForeignKey) : String
      key = operation.foreign_key
      "ALTER TABLE #{quote(operation.table)} ADD CONSTRAINT #{quote(key.name)} #{references(key)}#{" NOT VALID" if operation.not_valid}"
    end

    def self.render(operation : Differ::ValidateForeignKey) : String
      "ALTER TABLE #{quote(operation.table)} VALIDATE CONSTRAINT #{quote(operation.name)}"
    end

    def self.render(operation : Differ::DropForeignKey) : String
      "ALTER TABLE #{quote(operation.table)} DROP CONSTRAINT #{quote(operation.name)}"
    end

    private def self.references(key : Catalog::ForeignKey) : String
      raise ArgumentError.new("unsupported ON DELETE action: #{key.on_delete}") unless ON_DELETE.includes?(key.on_delete)
      clause = "FOREIGN KEY (#{quote(key.column)}) REFERENCES #{quote(key.references_table)} (#{quote(key.references_column)})"
      key.on_delete == "NO ACTION" ? clause : "#{clause} ON DELETE #{key.on_delete}"
    end
  end
end
