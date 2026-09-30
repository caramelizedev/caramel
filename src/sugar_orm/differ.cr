require "set"
require "./catalog"
require "./introspection"
require "./ddl"

module SugarORM
  # Compares the declared schema with a live catalog. It derives only changes
  # that keep data and running code safe; anything else becomes a Halt that
  # explains the risk and the remedy.
  module Differ
    record CreateTable, table : Catalog::Table
    record AddColumn, table : String, column : Catalog::Column
    record RenameColumn, table : String, from : String, to : String
    record DropColumn, table : String, column : String, explicit : Bool
    record AlterNull, table : String, column : String, nullable : Bool
    record AlterDefault, table : String, column : String, default : String?
    record AlterType, table : String, column : String, sql_type : String
    record AddIndex, table : String, index : Catalog::Index, concurrently : Bool
    record DropIndex, table : String, name : String
    record AddForeignKey, table : String, foreign_key : Catalog::ForeignKey, not_valid : Bool
    record ValidateForeignKey, table : String, name : String
    record DropForeignKey, table : String, name : String

    alias Operation = CreateTable | AddColumn | RenameColumn | DropColumn |
                      AlterNull | AlterDefault | AlterType |
                      AddIndex | DropIndex |
                      AddForeignKey | ValidateForeignKey | DropForeignKey

    # The Crystal type a halt suggests for a column's SQL type.
    CRYSTAL_TYPES = {
      "text"                     => "String",
      "integer"                  => "Int32",
      "bigint"                   => "Int64",
      "boolean"                  => "Bool",
      "double precision"         => "Float64",
      "timestamp with time zone" => "Time",
    }

    # `--dev-override` turns an overridable halt into its operation.
    record Halt,
      subject : String,
      message : String,
      remediation : String,
      overridable : Bool = true do
      def to_s(io : IO) : Nil
        io << "HALT " << subject << ": " << message << "\n  Remediation: " << remediation
      end

      # RFC-0005 MRDP; `subject` is `table.column` or an index name.
      def to_mrdp(io : IO) : Nil
        io << "ERR DIFF_HALT at " << subject << '\n'
        io << "MSG: " << message << '\n'
        io << "FIX: " << remediation << '\n'
      end
    end

    class Plan
      # Statements for one transactional migration.
      getter transactional = [] of Operation
      # CONCURRENTLY index changes and foreign key validation on existing
      # tables, for a separate migration that runs in autocommit.
      getter online = [] of Operation
      getter halts = [] of Halt
      getter overridden = [] of Halt
      # Ignored tables and catalog objects a schema cannot declare.
      getter notes = [] of String

      def empty? : Bool
        @transactional.empty? && @online.empty?
      end

      def clean? : Bool
        empty? && @halts.empty?
      end

      def to_s(io : IO) : Nil
        DDL.statements(@transactional + @online).each do |sql|
          sql.each_line { |line| io << "  " << line << '\n' }
        end
        @halts.each { |halt| io << halt << '\n' }
      end
    end

    def self.diff(declared : Array(Catalog::Table),
                  snapshot : Introspection::Snapshot,
                  dev_override : Bool = false) : Plan
      plan = diff(declared, snapshot.tables, dev_override)
      snapshot.invalid_indexes.each { |index| plan.halts << invalid_index(index) }
      plan.notes.concat(snapshot.skipped)
      plan
    end

    def self.diff(declared : Array(Catalog::Table),
                  actual : Array(Catalog::Table),
                  dev_override : Bool = false) : Plan
      plan = Plan.new
      existing = actual.index_by(&.name)
      names = declared.map(&.name).to_set
      actual.each do |table|
        if table.name.starts_with?("caramel_")
          plan.notes << "ignored table #{table.name} (owned by Caramel)"
        elsif !names.includes?(table.name)
          plan.notes << "ignored table #{table.name} (no schema declares it)"
        end
      end
      create(declared.reject { |table| existing.has_key?(table.name) }, plan)
      declared.each do |table|
        existing[table.name]?.try { |current| alter(table, current, plan, dev_override) }
      end
      plan
    end

    # New tables are empty, so their indexes and foreign keys are built inline.
    # Tables are ordered so each one follows the new tables it references; a
    # reference cycle falls back to constraints added after every table.
    private def self.create(tables : Array(Catalog::Table), plan : Plan) : Nil
      pending = tables.dup
      deferred = [] of Operation
      waiting = ->(table : Catalog::Table, key : Catalog::ForeignKey) do
        target = key.references_table
        target != table.name && pending.any? { |other| other.name == target }
      end
      until pending.empty?
        ready = pending.find do |candidate|
          candidate.foreign_keys.none? { |key| waiting.call(candidate, key) }
        end
        table = ready || pending.first
        later, inline = table.foreign_keys.partition { |key| waiting.call(table, key) }
        pending.delete(table)
        created = table.copy_with(
          foreign_keys: inline,
          indexes: [] of Catalog::Index,
          drops: [] of String,
        )
        plan.transactional << CreateTable.new(created)
        table.indexes.each do |index|
          plan.transactional << AddIndex.new(table.name, index, concurrently: false)
        end
        later.each { |key| deferred << AddForeignKey.new(table.name, key, not_valid: false) }
      end
      plan.transactional.concat(deferred)
    end

    # ameba:disable Metrics/CyclomaticComplexity -- one branch per kind of column change
    private def self.alter(declared : Catalog::Table,
                           current : Catalog::Table,
                           plan : Plan,
                           dev_override : Bool) : Nil
      table = declared.name
      columns = current.columns.index_by(&.name)
      names = declared.columns.map(&.name).to_set
      renamed = {} of String => String
      dropped, claimed = Set(String).new, Set(String).new
      renames = [] of Operation
      changes = [] of Operation
      drops = [] of Operation
      key_drops = [] of Operation
      key_adds = [] of Operation

      declared.columns.each do |column|
        actual = columns[column.name]?
        source = column.renamed_from
        if source && !names.includes?(source) && !declared.drops.includes?(source) &&
           columns.has_key?(source)
          if actual
            plan.halts << rename_conflict(table, column.name, source)
            claimed << source
            next
          end
          renames << RenameColumn.new(table, source, column.name)
          renamed[source] = column.name
          actual = columns[source]
        end
        if actual
          compare(table, column, actual, plan, dev_override, changes)
        elsif column.nullable || column.default || column.identity
          changes << AddColumn.new(table, column)
        else
          halt(plan, dev_override, missing_default(table, column)) do
            changes << AddColumn.new(table, column)
          end
        end
      end

      current.columns.each do |column|
        next if names.includes?(column.name) || renamed.has_key?(column.name) ||
                claimed.includes?(column.name)
        if declared.drops.includes?(column.name)
          drops << DropColumn.new(table, column.name, explicit: true)
          dropped << column.name
        else
          halt(plan, dev_override, undeclared_column(table, column.name)) do
            drops << DropColumn.new(table, column.name, explicit: false)
            dropped << column.name
          end
        end
      end

      renamed_indexes = current.indexes.map do |index|
        index.copy_with(columns: index.columns.map { |column| renamed[column]? || column })
      end
      indexes = renamed_indexes.index_by(&.name)
      declared.indexes.each do |index|
        found = indexes[index.name]?
        next if found == index
        plan.online << DropIndex.new(table, index.name) if found
        plan.online << AddIndex.new(table, index, concurrently: true)
      end
      current.indexes.each do |index|
        next if declared.indexes.any? { |wanted| wanted.name == index.name }
        next if index.columns.any? { |column| dropped.includes?(column) }
        plan.online << DropIndex.new(table, index.name)
      end

      renamed_keys = current.foreign_keys.map do |key|
        key.copy_with(column: renamed[key.column]? || key.column)
      end
      keys = renamed_keys.index_by(&.name)
      declared.foreign_keys.each do |key|
        found = keys[key.name]?
        next if found == key
        key_drops << DropForeignKey.new(table, key.name) if found
        key_adds << AddForeignKey.new(table, key, not_valid: true)
        plan.online << ValidateForeignKey.new(table, key.name)
      end
      current.foreign_keys.each do |key|
        next if declared.foreign_keys.any? { |wanted| wanted.name == key.name }
        next if dropped.includes?(key.column)
        key_drops << DropForeignKey.new(table, key.name)
      end

      steps = [key_drops, renames, changes, drops, key_adds]
      steps.each { |operations| plan.transactional.concat(operations) }
    end

    private def self.compare(table : String,
                             column : Catalog::Column,
                             actual : Catalog::Column,
                             plan : Plan,
                             dev_override : Bool,
                             changes : Array(Operation)) : Nil
      if column.primary != actual.primary || column.identity != actual.identity
        plan.halts << key_changed(table, column, actual)
        return
      end
      if column.sql_type != actual.sql_type
        halt(plan, dev_override, type_changed(table, column, actual)) do
          changes << AlterType.new(table, column.name, column.sql_type)
        end
      end
      if column.nullable && !actual.nullable
        changes << AlterNull.new(table, column.name, nullable: true)
      elsif !column.nullable && actual.nullable
        halt(plan, dev_override, not_null_added(table, column)) do
          changes << AlterNull.new(table, column.name, nullable: false)
        end
      end
      return if column.identity || column.default == actual.default
      changes << AlterDefault.new(table, column.name, column.default)
    end

    private def self.halt(plan : Plan, dev_override : Bool, halt : Halt, &) : Nil
      if dev_override && halt.overridable
        plan.overridden << halt
        yield
      else
        plan.halts << halt
      end
    end

    private def self.crystal_type(sql_type : String) : String
      CRYSTAL_TYPES[sql_type]? || sql_type
    end

    private def self.invalid_index(index : String) : Halt
      Halt.new(
        subject: index,
        message: "index is INVALID, left behind by a failed CREATE INDEX CONCURRENTLY.",
        remediation: "run DROP INDEX CONCURRENTLY #{DDL.quote(index)}; then diff again.",
        overridable: false,
      )
    end

    private def self.rename_conflict(table : String,
                                     column : String,
                                     source : String) : Halt
      Halt.new(
        subject: "#{table}.#{column}",
        message: "both #{column} and its renamed_from source #{source} exist.",
        remediation: "remove renamed_from: :#{source} if the rename is finished, " \
                     "or record drop_column :#{source}.",
        overridable: false,
      )
    end

    private def self.missing_default(table : String, column : Catalog::Column) : Halt
      field = "field #{column.name} : #{crystal_type(column.sql_type)} = …"
      Halt.new(
        subject: "#{table}.#{column.name}",
        message: "NOT NULL column without a default cannot be added to the existing " \
                 "#{table} table: existing rows have no value for it.",
        remediation: "give the field a default (#{field}) or make it nilable; " \
                     "in development, --dev-override adds it as declared.",
      )
    end

    private def self.undeclared_column(table : String, column : String) : Halt
      Halt.new(
        subject: "#{table}.#{column}",
        message: "column exists in the database but no field declares it; " \
                 "SugarORM never drops a column it was not told to.",
        remediation: "declare the field again, " \
                     "mark its replacement renamed_from: :#{column}, " \
                     "or record the intent with drop_column :#{column}.",
      )
    end

    private def self.key_changed(table : String,
                                 column : Catalog::Column,
                                 actual : Catalog::Column) : Halt
      Halt.new(
        subject: "#{table}.#{column.name}",
        message: "primary key or identity differs from the database " \
                 "(declared primary: #{column.primary}, identity: #{column.identity}; " \
                 "database primary: #{actual.primary}, identity: #{actual.identity}).",
        remediation: "SugarORM does not rewrite primary keys; " \
                     "create a new table and copy the rows deliberately.",
        overridable: false,
      )
    end

    private def self.type_changed(table : String,
                                  column : Catalog::Column,
                                  actual : Catalog::Column) : Halt
      Halt.new(
        subject: "#{table}.#{column.name}",
        message: "declared type #{column.sql_type} differs from #{actual.sql_type} " \
                 "in the database; changing it rewrites #{table} " \
                 "under an exclusive lock.",
        remediation: "add a new field with the new type, backfill it, " \
                     "and drop_column :#{actual.name}; " \
                     "in development, --dev-override alters the type.",
      )
    end

    private def self.not_null_added(table : String, column : Catalog::Column) : Halt
      Halt.new(
        subject: "#{table}.#{column.name}",
        message: "SET NOT NULL scans #{table} under an exclusive lock " \
                 "and fails if any row holds NULL.",
        remediation: "keep the field nilable, or backfill it and add a " \
                     "CHECK (#{column.name} IS NOT NULL) NOT VALID constraint " \
                     "by hand first; in development, --dev-override sets NOT NULL.",
      )
    end
  end
end
