require "./wording"

module SugarORM
  # The type-independent part of every changeset; `SugarORM::Invalid` holds one.
  abstract class AnyChangeset
    getter errors : Hash(String, Array(String)) = {} of String => Array(String)

    def valid? : Bool
      @errors.empty?
    end

    abstract def saved? : Bool

    # Adds an error under a column name or `"_base"`.
    def add_error(field : String, message : String) : Nil
      (@errors[field] ||= [] of String) << message
    end

    def error_messages : Array(String)
      @errors.flat_map do |field, messages|
        messages.map { |message| field == "_base" ? message : "#{field} #{message}" }
      end
    end
  end

  # Raised by the bang facade methods (`create!`, `update!`).
  class Invalid < Error
    getter changeset : AnyChangeset

    def initialize(@changeset : AnyChangeset)
      super("#{changeset.class} is invalid: #{changeset.error_messages.join("; ")}")
    end
  end

  # An explicit, validated mutation of schema `T`:
  #
  #     class Team::UpdateChangeset < SugarORM::Changeset(Team)
  #       param seats : Int32
  #
  #       def validate(cs)
  #         cs.validate_greater_than(:seats, 0)
  #       end
  #     end
  #
  # `Changeset.new(record, **changes)` builds an update and `Changeset.new(**changes)`
  # an insert; both accept exactly the declared params (checked at compile time).
  # Validations run on construction; `Repo.insert`/`Repo.update` persist.
  abstract class Changeset(T) < AnyChangeset
    @original : T? = nil
    @record : T? = nil
    @saved = false
    @changes = {} of String => Value
    @unique_constraints = [] of {String, String}
    # The constraint name, the column that takes the error and an explicit message.
    @check_constraints = [] of {String, String, String?}
    # The version a form or client says it loaded, when the schema is versioned.
    @expected_version : Int64? = nil
    @stale = false

    # Declares a permitted param; it must name a non-system field of `T` with a
    # compatible type.
    macro param(declaration)
      {% location = "\n  --> #{declaration.filename.id}:" +
                    "#{declaration.line_number}:#{declaration.column_number}" %}
      {% unless declaration.is_a?(TypeDeclaration) && declaration.value.is_a?(Nop) %}
        {% declaration.raise "param expects `param name : Type` (no default).\n" +
                             "Remediation: write it like `param seats : Int32`, " +
                             "naming a field of the schema." + location %}
      {% end %}
      {% schema = nil %}
      {% for ancestor in @type.ancestors %}
        {% if ancestor.name(generic_args: false).stringify == "SugarORM::Changeset" %}
          {% schema = ancestor.type_vars[0] %}
        {% end %}
      {% end %}
      {% fields = schema.constant(:SUGAR_FIELDS) %}
      {% unless fields %}
        {% declaration.raise "#{schema} has no `schema` block yet, " +
                             "so #{@type} cannot declare params.\n" +
                             "Remediation: define #{@type} after " +
                             "`schema \"table\" do ... end` in #{schema}." + location %}
      {% end %}
      {% name = declaration.var.id.stringify %}
      {% field = fields[name] %}
      {% unless field %}
        {% declaration.raise "param '#{name.id}' is not a field of #{schema}.\n" +
                             "Fields: #{fields.keys.join(", ").id}\n" +
                             "Remediation: rename the param to one of these fields, " +
                             "or add `field #{name.id} : Type` " +
                             "to #{schema}'s schema block." + location %}
      {% end %}
      {% if field[:system] %}
        {% declaration.raise "param '#{name.id}' names #{schema}'s " +
                             "system-managed column '#{name.id}' " +
                             "(primary key, timestamp or tenant), " +
                             "which changesets never write.\n" +
                             "Remediation: remove `param #{name.id}`." + location %}
      {% end %}
      {% declared = declaration.type.resolve %}
      {% column = parse_type(field[:type]).resolve %}
      {% unless declared <= column %}
        {% hint = field[:nullable] ? " (or its non-nil form)" : "" %}
        {% declaration.raise "param '#{name.id} : #{declaration.type}' " +
                             "does not match #{schema} field '#{name.id} : #{column}'.\n" +
                             "Remediation: declare " +
                             "`param #{name.id} : #{field[:declared].id}`#{hint.id}." +
                             location %}
      {% end %}
      {% constant = "SUGAR_PARAM_#{name.upcase.id}".id %}
      {% if @type.has_constant?(constant) %}
        {% declaration.raise "param '#{name.id}' is declared twice in #{@type}.\n" +
                             "Remediation: remove the duplicate `param #{name.id}`." +
                             location %}
      {% end %}
      {% accepted = declared.union_types.map { |member| "::#{member}" }.join(" | ") %}
      # {name, accepted value type}
      {{ constant }} = { {{ name }}, {{ accepted }} }
    end

    # Makes this changeset's insert an upsert on a unique index `T` declares:
    # `upsert on: :tea_id, update: [:sold]`, or `on: [:a, :b]` for several columns. A
    # tenanted schema's index also holds the tenant column, which the insert stamps. The
    # `update:` fields the changeset writes are set from the new row (with `updated_at` and
    # the version column); with none, the existing row stays as it is. Either way `record`
    # is the stored row. The key and `update:` fields must be params of this changeset.
    macro upsert(*, on, update = nil)
      {% call = @caller.first %}
      {% location = "\n  --> #{call.filename.id}:#{call.line_number}:#{call.column_number}" %}
      {% schema = nil %}
      {% for ancestor in @type.ancestors %}
        {% if ancestor.name(generic_args: false).stringify == "SugarORM::Changeset" %}
          {% schema = ancestor.type_vars[0] %}
        {% end %}
      {% end %}
      {% fields = schema.constant(:SUGAR_FIELDS) %}
      {% unless fields %}
        {% on.raise "#{schema} has no `schema` block yet, " +
                    "so #{@type} cannot declare an upsert.\n" +
                    "Remediation: define #{@type} after " +
                    "`schema \"table\" do ... end` in #{schema}." + location %}
      {% end %}
      {% if @type.has_constant?(:SUGAR_UPSERT) %}
        {% on.raise "#{@type} declares upsert twice.\n" +
                    "Remediation: keep one `upsert`." + location %}
      {% end %}
      {% columns = nil %}
      {% if on.is_a?(SymbolLiteral) %}
        {% columns = [on.id.stringify] %}
      {% elsif on.is_a?(ArrayLiteral) && !on.empty? && on.all?(&.is_a?(SymbolLiteral)) %}
        {% columns = on.map(&.id.stringify) %}
      {% end %}
      {% unless columns %}
        {% on.raise "upsert expects `upsert on: :column`, or `upsert on: [:a, :b]` " +
                    "for a multi-column unique index, " +
                    "optionally with `update: [:field, …]`." + location %}
      {% end %}
      {% targets = schema.constant(:SUGAR_UNIQUE_INDEXES) %}
      {% key = columns.join("_and_") %}
      {% unless targets[key] %}
        {% names = targets.keys.join(", ") %}
        {% on.raise "#{schema} has no unique index on #{columns.join(", ").id}.\n" +
                    "Unique indexes: #{targets.empty? ? "none".id : names.id}\n" +
                    "Remediation: add `index :#{columns.join(", :").id}, unique: true` " +
                    "to #{schema}'s schema block, or name one of its unique indexes." +
                    location %}
      {% end %}
      {% conflict = targets[key] %}
      {% updated = [] of Nil %}
      {% if update.is_a?(NilLiteral) %}
      {% elsif update.is_a?(ArrayLiteral) && update.all?(&.is_a?(SymbolLiteral)) %}
        {% for symbol in update %}
          {% field = symbol.id.stringify %}
          {% unless fields[field] %}
            {% on.raise "upsert updates '#{field.id}', which is not a field of #{schema}.\n" +
                        "Fields: #{fields.keys.join(", ").id}" + location %}
          {% end %}
          {% if conflict.includes?(field) %}
            {% on.raise "upsert cannot update '#{field.id}', " +
                        "which its conflict target matches.\n" +
                        "Remediation: remove :#{field.id} from update:." + location %}
          {% end %}
          {% if schema.has_constant?(:SUGAR_VERSION) && schema.constant(:SUGAR_VERSION) == field %}
            {% on.raise "upsert cannot update '#{field.id}', " +
                        "#{schema}'s version field; an upsert increments it.\n" +
                        "Remediation: remove :#{field.id} from update:." + location %}
          {% end %}
          {% updated << field %}
        {% end %}
      {% else %}
        {% on.raise "upsert's update: takes field symbols, like `update: [:sold]`." +
                    location %}
      {% end %}
      # {conflict columns, declared key columns, columns set on conflict, where it was declared}
      SUGAR_UPSERT = {
        conflict: [{% for column in conflict %}{{ column }}, {% end %}] of String,
        keys:     [{% for column in columns %}{{ column }}, {% end %}] of String,
        update:   [{% for column in updated %}{{ column }}, {% end %}] of String,
        at:       {{ location }},
      }
    end

    macro inherited
      # The typed constructors are generated once every `param` is known, so an
      # unknown keyword or a mistyped value fails at the caller's line.
      macro finished
        \{% names = @type.constants.select(&.starts_with?("SUGAR_PARAM_")) %}
        \{% params = names.map { |name| @type.constant(name) } %}
        \{% schema = nil %}
        \{% for ancestor in @type.ancestors %}
          \{% if ancestor.name(generic_args: false).stringify == "SugarORM::Changeset" %}
            \{% schema = ancestor.type_vars[0] %}
          \{% end %}
        \{% end %}
        \{% unset = " | ::Nil | ::SugarORM::Unset = ::SugarORM::UNSET" %}
        \{% declared = params.map { |param| "#{param[0].id} : #{param[1].id}" + unset } %}
        \{% keywords = declared.join(", ") %}
        \{% after_record = params.empty? ? "" : ", *, #{keywords.id}" %}

        def initialize(record : ::\{{schema}}\{{after_record.id}})
          @original = record
          \{% for param in params %}
            \{% name = param[0].id %}
            unless \{{name}}.is_a?(::SugarORM::Unset)
              __sugar_put(\{{param[0]}}, ::\{{schema}}.__sugar_encode_\{{name}}(\{{name}}))
            end
          \{% end %}
          __sugar_prepare
        end

        def initialize\{% unless params.empty? %}(*, \{{keywords.id}})\{% end %}
          \{% for param in params %}
            \{% name = param[0].id %}
            unless \{{name}}.is_a?(::SugarORM::Unset)
              __sugar_put(\{{param[0]}}, ::\{{schema}}.__sugar_encode_\{{name}}(\{{name}}))
            end
          \{% end %}
          __sugar_prepare
        end

        \{% if @type.has_constant?(:SUGAR_UPSERT) %}
          \{% upsert = @type.constant(:SUGAR_UPSERT) %}
          \{% fields = schema.constant(:SUGAR_FIELDS) %}
          \{% known = params.map { |param| param[0] } %}
          \{% for column in upsert[:keys] + upsert[:update] %}
            \{% unless known.includes?(column) %}
              \{% raise "upsert names '#{column.id}', which is not a param of #{@type}.\n" +
                        "Remediation: add `param #{column.id} : " +
                        "#{fields[column][:declared].id}` to #{@type}." + upsert[:at] %}
            \{% end %}
          \{% end %}

          # :nodoc:
          def __sugar_upsert : NamedTuple(conflict: Array(String),
                                          keys: Array(String),
                                          update: Array(String))?
            {
              conflict: [\{% for c in upsert[:conflict] %}\{{ c }}, \{% end %}] of String,
              keys:     [\{% for c in upsert[:keys] %}\{{ c }}, \{% end %}] of String,
              update:   [\{% for c in upsert[:update] %}\{{ c }}, \{% end %}] of String,
            }
          end
        \{% end %}
      end
    end

    # Override to validate; called once on construction with the changeset itself.
    def validate(cs) : Nil
    end

    def insert? : Bool
      @original.nil?
    end

    def saved? : Bool
      @saved
    end

    # True when an update found the record changed since it was loaded, or since the
    # version this changeset was given.
    def stale? : Bool
      @stale
    end

    # :nodoc:
    def __sugar_upsert : NamedTuple(conflict: Array(String),
      keys: Array(String),
      update: Array(String))?
      nil
    end

    # The fields this changeset writes; for an update only those that differ
    # from the record.
    def changes : Hash(String, Value)
      @changes.dup
    end

    # The stored row after a save; for an update the original before it.
    def record : T
      @record || @original || raise Error.new(
        "#{self.class} has not been inserted, so it has no record yet"
      )
    end

    def add_error(field : T::Field, message : String) : Nil
      add_error(T.__sugar_column(field), message)
    end

    # Each field must be present: not nil and, for strings, not blank.
    def validate_required(*fields : T::Field, message : String = Wording.required) : Nil
      fields.each do |field|
        value = current(field)
        add_error(field, message) if value.nil? || (value.is_a?(String) && value.blank?)
      end
    end

    # A changed string must not be blank.
    def validate_presence(field : T::Field, message : String = Wording.blank) : Nil
      column = T.__sugar_column(field)
      return unless @changes.has_key?(column)
      value = @changes[column]
      add_error(column, message) if value.nil? || (value.is_a?(String) && value.blank?)
    end

    def validate_greater_than(field : T::Field,
                              than : Number,
                              message : String = Wording.greater_than(than)) : Nil
      number(field) { |value| add_error(field, message) unless value > than }
    end

    def validate_less_than(field : T::Field,
                           than : Number,
                           message : String = Wording.less_than(than)) : Nil
      number(field) { |value| add_error(field, message) unless value < than }
    end

    def validate_length(field : T::Field, min : Int32? = nil, max : Int32? = nil) : Nil
      string(field) do |value|
        if min && value.size < min
          add_error(field, Wording.too_short(min))
        elsif max && value.size > max
          add_error(field, Wording.too_long(max))
        end
      end
    end

    def validate_format(field : T::Field,
                        format : Regex,
                        message : String = Wording.invalid_format) : Nil
      string(field) { |value| add_error(field, message) unless format.matches?(value) }
    end

    def validate_inclusion(field : T::Field,
                           in values : Enumerable,
                           message : String = Wording.invalid) : Nil
      column = T.__sugar_column(field)
      return unless @changes.has_key?(column)
      value = @changes[column]
      listed = value.nil? || values.any? do |item|
        T.__sugar_encode_candidate(column, item) == value
      end
      add_error(field, message) unless listed
    end

    # Maps a unique violation (SQLSTATE 23505) of the index that leads with
    # `field` to an error on it, instead of raising, when this changeset saves.
    def unique_constraint(field : T::Field,
                          message : String = Wording.taken) : Nil
      @unique_constraints << {T.__sugar_column(field), message}
    end

    # Maps a violation (SQLSTATE 23514) of the range check `check`, named by its
    # column, to an error on that column, instead of raising, when this changeset
    # saves. Without a *message* the error says how far the value is out of range.
    def check_constraint(check : Symbol, message : String? = nil) : Nil
      declared = declared_check(check)
      column = declared.column
      unless column
        raise ArgumentError.new("check_constraint(:#{check}) names an expression check, " \
                                "which bounds no field; pass on: :field")
      end
      @check_constraints << {declared.name, column, message}
    end

    # Maps a violation of any declared check, such as a named SQL expression, to
    # an error on *field*.
    def check_constraint(check : Symbol, *, on field : T::Field,
                         message : String = Wording.invalid) : Nil
      @check_constraints << {declared_check(check).name, T.__sugar_column(field), message}
    end

    # :nodoc:
    def __sugar_insert : Nil
      unless insert?
        raise ArgumentError.new(
          "#{self.class} was built from a record; use SugarORM::Repo.update"
        )
      end
      if @expected_version
        raise ArgumentError.new(
          "#{self.class} sets #{T.__sugar_version_column}, which only an update checks; " \
          "an insert starts at 0"
        )
      end
      return if @saved || !valid?
      columns = @changes.keys
      values = @changes.values
      {% if T.has_constant?(:SUGAR_TENANT) %}
        columns << T.__sugar_tenant_column
        values << T.__sugar_tenant_stamp
      {% end %}
      upsert = __sugar_upsert
      sql = String.build do |io|
        io << "INSERT INTO " << T.__sugar_quoted_table
        if columns.empty?
          io << " DEFAULT VALUES"
        else
          io << " (" << columns.map { |column| %("#{column}") }.join(", ") << ") VALUES ("
          io << (1..columns.size).join(", ") { |index| "$#{index}" } << ")"
        end
        write_conflict(io, upsert) if upsert
        io << " RETURNING " << T.__sugar_select_list
      end
      write do
        stored = Repo.query_one?(sql, values) { |rows| T.from_row(rows) }
        next stored if stored
        upsert ? existing_row(upsert[:conflict], columns, values) : nil
      end
    end

    # :nodoc:
    def __sugar_update : Nil
      original = @original || raise ArgumentError.new(
        "#{self.class} was built without a record; use SugarORM::Repo.insert"
      )
      return if @saved || !valid?
      version = loaded_version(original)
      expected = @expected_version
      if version && expected && expected != version[1]
        mark_stale
        return
      end
      if @changes.empty?
        @record = original
        @saved = true
        return
      end
      assignments = @changes.keys.map_with_index do |column, index|
        %("#{column}" = $#{index + 1})
      end
      assignments << %("#{version[0]}" = "#{version[0]}" + 1) if version
      assignments << %("updated_at" = CURRENT_TIMESTAMP) if T.__sugar_timestamps?
      args = @changes.values
      args << original.__sugar_primary_value
      predicate = %("#{T.__sugar_primary_key}" = $#{args.size})
      if version
        args << version[1]
        predicate += %( AND "#{version[0]}" = $#{args.size})
      end
      sql = "UPDATE #{T.__sugar_quoted_table} SET #{assignments.join(", ")} " \
            "WHERE #{predicate}#{SugarORM.tenant_filter(T, args)} " \
            "RETURNING #{T.__sugar_select_list}"
      write { Repo.query_one?(sql, args) { |rows| T.from_row(rows) } }
    end

    # :nodoc:
    def __sugar_delete : Nil
      original = @original || raise ArgumentError.new(
        "#{self.class} was built without a record; there is nothing to delete"
      )
      if Repo.delete(original)
        @record = original
        @saved = true
      else
        add_error("_base", Wording.record_gone)
      end
    end

    private def __sugar_put(column : String, value) : Nil
      if column == T.__sugar_version_column
        @expected_version = value.as?(Int32 | Int64).try(&.to_i64)
        return
      end
      original = @original
      return if original && original.__sugar_get(column) == value
      @changes[column] = value
    end

    # NOT NULL checks (an insert must supply every column without a default),
    # then the user's `validate(cs)`.
    private def __sugar_prepare : Nil
      T.__sugar_not_null_columns.each do |column|
        missing = if @changes.has_key?(column)
                    @changes[column].nil?
                  else
                    insert? && T.__sugar_required_columns.includes?(column)
                  end
        add_error(column, Wording.required) if missing
      end
      require_upsert_keys
      validate(self)
    end

    # An upsert's key is its conflict target, so an insert must supply every key column.
    private def require_upsert_keys : Nil
      upsert = __sugar_upsert
      return unless upsert && insert?
      upsert[:keys].each do |column|
        next if @changes.has_key?(column) && !@changes[column].nil?
        next if @errors[column]?.try(&.includes?(Wording.required))
        add_error(column, Wording.required)
      end
    end

    # The conflict clause of an upsert insert: update what `update:` names and the changeset
    # writes, or leave the existing row alone.
    private def write_conflict(io : IO, upsert) : Nil
      io << " ON CONFLICT (" << upsert[:conflict].map { |column| %("#{column}") }.join(", ")
      io << ")"
      updates = upsert[:update].select { |column| @changes.has_key?(column) }
      if updates.empty?
        io << " DO NOTHING"
        return
      end
      assignments = updates.map { |column| %("#{column}" = EXCLUDED."#{column}") }
      assignments << %("updated_at" = CURRENT_TIMESTAMP) if T.__sugar_timestamps?
      if version = T.__sugar_version_column
        assignments << %("#{version}" = #{T.__sugar_quoted_table}."#{version}" + 1)
      end
      io << " DO UPDATE SET " << assignments.join(", ")
    end

    # The row a DO NOTHING upsert met, read by the conflict columns (the tenant's included)
    # in a second statement: a CTE would share the INSERT's snapshot and miss a row that
    # committed meanwhile.
    private def existing_row(conflict : Array(String),
                             columns : Array(String),
                             values : Array(Value)) : T?
      args = conflict.map { |column| values[columns.index!(column)] }
      predicate = conflict.map_with_index { |column, index| %("#{column}" = $#{index + 1}) }
      sql = "SELECT #{T.__sugar_select_list} FROM #{T.__sugar_quoted_table} " \
            "WHERE #{predicate.join(" AND ")}"
      Repo.query_one?(sql, args) { |rows| T.from_row(rows) }
    end

    # The version column's name and the loaded record's version, for a versioned schema.
    private def loaded_version(original : T) : {String, Int64}?
      column = T.__sugar_version_column || return
      value = original.__sugar_get(column).as?(Int32 | Int64) || return
      {column, value.to_i64}
    end

    private def mark_stale : Nil
      @stale = true
      add_error("_base", Wording.record_stale)
    end

    # No row matched the write. On a versioned schema a row still visible to this changeset's
    # tenant means someone changed it; otherwise it is gone.
    private def missing_row : Nil
      if row_exists?
        mark_stale
      else
        add_error("_base", Wording.record_gone)
      end
    end

    private def row_exists? : Bool
      return false unless T.__sugar_version_column
      original = @original || return false
      args = [original.__sugar_primary_value] of Value
      sql = %(SELECT 1 FROM #{T.__sugar_quoted_table} WHERE "#{T.__sugar_primary_key}" = $1) +
            SugarORM.tenant_filter(T, args)
      !Repo.query_one?(sql, args, &.read(Int32)).nil?
    end

    # Runs the write; inside a transaction a changeset with unique or check
    # constraints writes under a savepoint so a mapped violation leaves the
    # transaction usable.
    # The block is captured so its query is compiled once, not once per path.
    private def write(&query : -> T?) : Nil
      stored = if @unique_constraints.empty? && @check_constraints.empty?
                 query.call
               else
                 begin
                   Repo.in_transaction? ? Repo.transaction { query.call } : query.call
                 rescue ex : UniqueViolation
                   constraint = constraint_for(ex)
                   raise ex unless constraint
                   add_error(constraint[0], constraint[1])
                   return
                 rescue ex : CheckViolation
                   entry = check_for(ex)
                   raise ex unless entry
                   add_error(entry[1], entry[2] || range_message(entry[0]))
                   return
                 end
               end
      if stored
        @record = stored
        @saved = true
      else
        missing_row
      end
    end

    # The declared check constraint the violation names.
    private def check_for(violation : CheckViolation) : {String, String, String?}?
      return unless violation.table.nil? || violation.table == T.__sugar_table_name
      @check_constraints.find { |(name, _, _)| name == violation.constraint }
    end

    # The check `check` of `T`, or an ArgumentError listing the checks it declares.
    private def declared_check(check : Symbol) : Catalog::Check
      name = "check_#{T.__sugar_table_name}_#{check}"
      T.__sugar_checks.find { |declared| declared.name == name } || begin
        prefix = "check_#{T.__sugar_table_name}_"
        suffixes = T.__sugar_checks.map(&.name.lchop(prefix))
        raise ArgumentError.new(
          "#{T} declares no check named #{check}; its checks: #{suffixes.join(", ")}")
      end
    end

    # Says how the column's value breaks the range check named *name*.
    private def range_message(name : String) : String
      check = T.__sugar_checks.find! { |declared| declared.name == name }
      column = check.column || return Wording.invalid
      value = @changes.has_key?(column) ? @changes[column] : @original.try(&.__sugar_get(column))
      return Wording.invalid unless value.is_a?(Int32 | Int64)
      min, max = check.min, check.max
      if min && value < min
        Wording.at_least(min)
      elsif max && value > max
        Wording.at_most(max)
      else
        Wording.invalid
      end
    end

    # The declared unique constraint whose column leads the violated index.
    private def constraint_for(violation : UniqueViolation) : {String, String}?
      table = T.__sugar_table_name
      @unique_constraints.find { |(column, _)| violation.on?(table, column) }
    end

    private def current(field : T::Field) : Value
      column = T.__sugar_column(field)
      return @changes[column] if @changes.has_key?(column)
      @original.try(&.__sugar_get(column))
    end

    private def number(field : T::Field, & : Float64 | Int32 | Int64 ->) : Nil
      column = T.__sugar_column(field)
      return unless @changes.has_key?(column)
      case value = @changes[column]
      when Int32, Int64, Float64 then yield value
      when Nil
      else
        raise ArgumentError.new("#{self.class}: '#{column}' is not numeric, " \
                                "so it cannot take a numeric validation")
      end
    end

    private def string(field : T::Field, & : String ->) : Nil
      column = T.__sugar_column(field)
      return unless @changes.has_key?(column)
      case value = @changes[column]
      when String then yield value
      when Nil
      else
        raise ArgumentError.new("#{self.class}: '#{column}' is not a String, " \
                                "so it cannot take a string validation")
      end
    end
  end
end
