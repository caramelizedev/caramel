require "json"

module SugarORM
  # A pure, immutable row type. Declare its table once:
  #
  #     struct Team < SugarORM::Schema
  #       schema "teams" do
  #         field id : Int64, primary: true
  #         field name : String
  #         field seats : Int32 = 5
  #         timestamps
  #         has_many users : User
  #       end
  #
  #       scope larger_than(seats : Int32) { where("seats > ?", seats) }
  #     end
  #
  # `schema` generates getters, `with`, `from_row`, JSON, the `Team::Field`
  # enum, `Team::Query`, association sentinels, the catalog table and the
  # facade (`create`, `update`, `delete`).
  abstract struct Schema
    macro inherited
      macro finished
        \{% unless @type.abstract? || @type.has_constant?(:SUGAR_TABLE) %}
          \{% raise "#{@type} inherits SugarORM::Schema but never declares its table.\nRemediation: add `schema \"table_name\" do ... end` with at least `field id : Int64, primary: true` to #{@type}." %}
        \{% end %}
      end
    end

    {% for name in %w(field timestamps belongs_to has_many has_one index drop_column) %}
      # :nodoc:
      macro {{ name.id }}(*arguments, **options)
        \{% raise "`{{ name.id }}` belongs inside the schema block.\nRemediation: move it into `schema \"table\" do ... end` of #{@type}." %}
      end
    {% end %}

    macro schema(table, &block)
      {% unless table.is_a?(StringLiteral) && table =~ /\A[a-z][a-z0-9_]*\z/ %}
        {% table.raise "schema expects the table name as a lowercase snake_case string literal.\nRemediation: write it like `schema \"teams\" do ... end`." + "\n  --> #{table.filename.id}:#{table.line_number}:#{table.column_number}" %}
      {% end %}
      {% if @type.has_constant?(:SUGAR_TABLE) %}
        {% table.raise "#{@type} declares `schema` twice.\nRemediation: keep a single `schema \"#{table.id}\" do ... end` block." + "\n  --> #{table.filename.id}:#{table.line_number}:#{table.column_number}" %}
      {% end %}
      {% unless block %}
        {% table.raise "schema needs a block.\nRemediation: write `schema #{table} do\n  field id : Int64, primary: true\nend`." + "\n  --> #{table.filename.id}:#{table.line_number}:#{table.column_number}" %}
      {% end %}
      {% statements = block.body.is_a?(Expressions) ? block.body.expressions : (block.body.is_a?(Nop) ? [] of Nil : [block.body]) %}
      {% sql_types = {"String" => "text", "Int32" => "integer", "Int64" => "bigint", "Bool" => "boolean", "Float64" => "double precision", "Time" => "timestamp with time zone"} %}
      {% reserved = %w(db with update update! delete query create create! from_row to_json record class hash dup inspect to_s initialize self end def if unless while until case when in of out do then else elsif begin rescue ensure return yield nil true false and or not typeof sizeof alias struct module enum lib fun macro include extend require abstract private protected super previous_def) %}
      {% owner_key = @type.name(generic_args: false).stringify.split("::").last.underscore + "_id" %}
      {% columns = [] of Nil %}
      {% associations = [] of Nil %}
      {% indexes = [] of Nil %}
      {% explicit_indexes = [] of Nil %}
      {% foreign_keys = [] of Nil %}
      {% drops = [] of Nil %}
      {% primary = [] of Nil %}
      {% timestamps = [] of Nil %}

      {% for statement in statements %}
        {% unless statement.is_a?(Call) && statement.receiver.is_a?(Nop) && statement.block.is_a?(Nop) %}
          {% statement.raise "Unknown schema declaration `#{statement}`.\nRemediation: a schema block holds only field, timestamps, belongs_to, has_many, has_one, index and drop_column declarations." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
        {% end %}
        {% kind = statement.name.stringify %}
        {% named = statement.named_args.is_a?(Nop) ? [] of Nil : statement.named_args %}

        {% if kind == "field" %}
          {% declaration = statement.args[0] %}
          {% unless statement.args.size == 1 && declaration.is_a?(TypeDeclaration) %}
            {% statement.raise "field expects `field name : Type`.\nRemediation: write it like `field seats : Int32 = 5`, optionally with `primary: true` or `renamed_from: :old_name`." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
          {% end %}
          {% name = declaration.var.stringify %}
          {% options = {} of Nil => Nil %}
          {% for argument in named %}
            {% unless %w(primary renamed_from).includes?(argument.name.stringify) %}
              {% statement.raise "Unknown field option '#{argument.name}' on field '#{name.id}'.\nRemediation: fields accept only `primary: true` and `renamed_from: :old_name`." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
            {% end %}
            {% options[argument.name.stringify] = argument.value %}
          {% end %}
          {% type = declaration.type %}
          {% nullable = false %}
          {% scalar = nil %}
          {% if type.is_a?(Union) %}
            {% members = type.types.map(&.stringify.gsub(/\A::/, "")) %}
            {% others = members.reject { |member| member == "Nil" } %}
            {% if members.size == 2 && others.size == 1 %}
              {% nullable = true %}
              {% scalar = others[0] %}
            {% end %}
          {% elsif type.is_a?(Path) %}
            {% scalar = type.stringify.gsub(/\A::/, "") %}
          {% end %}
          {% unless sql_types[scalar] %}
            {% declaration.raise "Unsupported type `#{type}` for field '#{name.id}'.\nSupported: String, Int32, Int64, Bool, Float64 and Time, each optionally nilable (`String?`).\nRemediation: declare `field #{name.id} : String` (or another supported type) and convert in your own code." + "\n  --> #{declaration.filename.id}:#{declaration.line_number}:#{declaration.column_number}" %}
          {% end %}
          {% value = declaration.value %}
          {% default = nil %}
          {% literal = nil %}
          {% if value.is_a?(Nop) %}
          {% elsif value.is_a?(NilLiteral) %}
            {% unless nullable %}
              {% declaration.raise "Field '#{name.id} : #{type}' cannot default to nil.\nRemediation: make it `#{scalar.id}?` or give a #{scalar.id} literal default." + "\n  --> #{declaration.filename.id}:#{declaration.line_number}:#{declaration.column_number}" %}
            {% end %}
          {% elsif value.is_a?(NumberLiteral) && (scalar == "Float64" || (%w(Int32 Int64).includes?(scalar) && value.kind.stringify =~ /\A:[iu]/)) %}
            {% default = value.stringify.gsub(/_?[iuf](8|16|32|64|128)\z/, "").gsub(/_/, "") %}
            {% literal = value %}
          {% elsif value.is_a?(StringLiteral) && scalar == "String" %}
            {% default = "'" + value.gsub(/'/, "''") + "'" %}
            {% literal = value %}
          {% elsif value.is_a?(BoolLiteral) && scalar == "Bool" %}
            {% default = value.stringify %}
            {% literal = value %}
          {% else %}
            {% declaration.raise "Default `#{value}` for field '#{name.id} : #{type}' is not a compile-time #{scalar.id} literal.\nDefaults become SQL column defaults, so they must be literals (`5`, `\"x\"`, `true`, `2.5`); Time fields take none.\nRemediation: write a literal default, or drop it and set the value in a changeset." + "\n  --> #{declaration.filename.id}:#{declaration.line_number}:#{declaration.column_number}" %}
          {% end %}
          {% is_primary = false %}
          {% if options.keys.includes?("primary") %}
            {% unless options["primary"].is_a?(BoolLiteral) %}
              {% statement.raise "primary: takes `true` or `false`.\nRemediation: write `field #{name.id} : Int64, primary: true`." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
            {% end %}
            {% is_primary = options["primary"] == true %}
          {% end %}
          {% if is_primary %}
            {% unless scalar == "Int64" && !nullable && value.is_a?(Nop) %}
              {% declaration.raise "The primary key '#{name.id}' must be a non-nilable Int64 without a default (it becomes an identity column).\nRemediation: declare `field #{name.id} : Int64, primary: true`." + "\n  --> #{declaration.filename.id}:#{declaration.line_number}:#{declaration.column_number}" %}
            {% end %}
            {% unless primary.empty? %}
              {% declaration.raise "#{@type} already has the primary key '#{primary[0].id}'.\nRemediation: keep a single `primary: true` field." + "\n  --> #{declaration.filename.id}:#{declaration.line_number}:#{declaration.column_number}" %}
            {% end %}
            {% primary << name %}
          {% end %}
          {% renamed = nil %}
          {% if options.keys.includes?("renamed_from") %}
            {% source = options["renamed_from"] %}
            {% unless (source.is_a?(SymbolLiteral) || source.is_a?(StringLiteral)) && source.id.stringify =~ /\A[a-z][a-z0-9_]*\z/ && source.id.stringify != name %}
              {% statement.raise "renamed_from: must name the old column as a symbol other than '#{name.id}', like `renamed_from: :email`." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
            {% end %}
            {% renamed = source.id.stringify %}
          {% end %}
          {% columns << {node: declaration, name: name, declared: nullable ? "#{scalar.id}?" : scalar, type: nullable ? "::#{scalar.id} | ::Nil" : "::#{scalar.id}", scalar: scalar, nullable: nullable, sql_type: sql_types[scalar], default: default, literal: literal, primary: is_primary, system: is_primary, renamed_from: renamed} %}

        {% elsif kind == "timestamps" %}
          {% unless statement.args.empty? && named.empty? %}
            {% statement.raise "timestamps takes no arguments; it adds created_at and updated_at." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
          {% end %}
          {% unless timestamps.empty? %}
            {% statement.raise "timestamps is declared twice.\nRemediation: keep one `timestamps`." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
          {% end %}
          {% timestamps << true %}
          {% for stamp in %w(created_at updated_at) %}
            {% columns << {node: statement, name: stamp, declared: "Time", type: "::Time", scalar: "Time", nullable: false, sql_type: "timestamp with time zone", default: "CURRENT_TIMESTAMP", literal: nil, primary: false, system: true, renamed_from: nil} %}
          {% end %}

        {% elsif kind == "belongs_to" || kind == "has_many" || kind == "has_one" %}
          {% declaration = statement.args[0] %}
          {% unless statement.args.size == 1 && declaration.is_a?(TypeDeclaration) && declaration.value.is_a?(Nop) %}
            {% statement.raise "#{kind.id} expects `#{kind.id} name : Type`, like `#{kind.id} #{kind == "has_many" ? "users : User".id : "team : Team".id}`." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
          {% end %}
          {% name = declaration.var.stringify %}
          {% target = declaration.type %}
          {% optional = false %}
          {% if target.is_a?(Union) && kind == "belongs_to" %}
            {% others = target.types.reject { |member| member.stringify.gsub(/\A::/, "") == "Nil" } %}
            {% if target.types.size == 2 && others.size == 1 %}
              {% optional = true %}
              {% target = others[0] %}
            {% end %}
          {% end %}
          {% unless target.is_a?(Path) %}
            {% declaration.raise "#{kind.id} '#{name.id}' must name one schema type#{kind == "belongs_to" ? ", optionally nilable (`User?`)".id : "".id}, not `#{declaration.type}`." + "\n  --> #{declaration.filename.id}:#{declaration.line_number}:#{declaration.column_number}" %}
          {% end %}
          {% key = nil %}
          {% for argument in named %}
            {% unless argument.name.stringify == "foreign_key" && kind != "belongs_to" && (argument.value.is_a?(SymbolLiteral) || argument.value.is_a?(StringLiteral)) && argument.value.id.stringify =~ /\A[a-z][a-z0-9_]*\z/ %}
              {% statement.raise "Unknown #{kind.id} option '#{argument.name}'.\nRemediation: #{kind == "belongs_to" ? "belongs_to takes no options; its column is `#{name.id}_id`".id : "the only option is `foreign_key: :column`".id}." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
            {% end %}
            {% key = argument.value.id.stringify %}
          {% end %}
          {% if kind == "belongs_to" %}
            {% key = name + "_id" %}
            {% columns << {node: declaration, name: key, declared: optional ? "Int64?" : "Int64", type: optional ? "::Int64 | ::Nil" : "::Int64", scalar: "Int64", nullable: optional, sql_type: "bigint", default: nil, literal: nil, primary: false, system: false, renamed_from: nil} %}
            {% foreign_keys << {name: "fk_#{table.id}_#{key.id}", column: key, target: target} %}
            {% indexes << {name: "index_#{table.id}_on_#{key.id}", columns: [key], unique: false} %}
          {% else %}
            {% key = key || owner_key %}
          {% end %}
          {% associations << {node: declaration, name: name, kind: kind, target: target, key: key, optional: optional} %}

        {% elsif kind == "index" %}
          {% unless !statement.args.empty? && statement.args.all? { |argument| (argument.is_a?(SymbolLiteral) || argument.is_a?(StringLiteral)) } %}
            {% statement.raise "index expects column symbols, like `index :name, unique: true`." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
          {% end %}
          {% unique = false %}
          {% for argument in named %}
            {% unless argument.name.stringify == "unique" && argument.value.is_a?(BoolLiteral) %}
              {% statement.raise "Unknown index option '#{argument.name}'.\nRemediation: the only option is `unique: true`." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
            {% end %}
            {% unique = argument.value %}
          {% end %}
          {% explicit_indexes << {node: statement, columns: statement.args.map(&.id.stringify), unique: unique} %}

        {% elsif kind == "drop_column" %}
          {% unless statement.args.size == 1 && named.empty? && (statement.args[0].is_a?(SymbolLiteral) || statement.args[0].is_a?(StringLiteral)) && statement.args[0].id.stringify =~ /\A[a-z][a-z0-9_]*\z/ %}
            {% statement.raise "drop_column expects one column symbol, like `drop_column :legacy_code`." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
          {% end %}
          {% drops << {node: statement, name: statement.args[0].id.stringify} %}

        {% else %}
          {% statement.raise "Unknown schema declaration '#{kind.id}'.\nRemediation: a schema block holds only field, timestamps, belongs_to, has_many, has_one, index and drop_column declarations." + "\n  --> #{statement.filename.id}:#{statement.line_number}:#{statement.column_number}" %}
        {% end %}
      {% end %}

      {% if primary.empty? %}
        {% table.raise "#{@type} has no primary key.\nRemediation: add `field id : Int64, primary: true` to the schema block of #{@type}." + "\n  --> #{table.filename.id}:#{table.line_number}:#{table.column_number}" %}
      {% end %}
      {% names = [] of Nil %}
      {% for column in columns %}
        {% unless column[:name] =~ /\A[a-z][a-z0-9_]*\z/ %}
          {% column[:node].raise "Column name '#{column[:name].id}' must be lowercase snake_case." + "\n  --> #{column[:node].filename.id}:#{column[:node].line_number}:#{column[:node].column_number}" %}
        {% end %}
        {% if names.includes?(column[:name]) %}
          {% column[:node].raise "#{@type} declares the column '#{column[:name].id}' twice.\nRemediation: remove the duplicate (timestamps adds created_at/updated_at; belongs_to x adds x_id)." + "\n  --> #{column[:node].filename.id}:#{column[:node].line_number}:#{column[:node].column_number}" %}
        {% end %}
        {% if reserved.includes?(column[:name]) %}
          {% column[:node].raise "'#{column[:name].id}' is reserved by SugarORM or Crystal and cannot be a field name.\nRemediation: rename the field (use `renamed_from:` to keep existing data)." + "\n  --> #{column[:node].filename.id}:#{column[:node].line_number}:#{column[:node].column_number}" %}
        {% end %}
        {% names << column[:name] %}
      {% end %}
      {% for association in associations %}
        {% if names.includes?(association[:name]) || reserved.includes?(association[:name]) %}
          {% association[:node].raise "Association '#{association[:name].id}' collides with a column or reserved name.\nRemediation: rename the association." + "\n  --> #{association[:node].filename.id}:#{association[:node].line_number}:#{association[:node].column_number}" %}
        {% end %}
        {% names << association[:name] %}
      {% end %}
      {% for index in explicit_indexes %}
        {% for column in index[:columns] %}
          {% unless columns.any? { |candidate| candidate[:name] == column } %}
            {% index[:node].raise "index references '#{column.id}', which is not a column of #{@type}.\nColumns: #{columns.map(&.[:name]).join(", ").id}" + "\n  --> #{index[:node].filename.id}:#{index[:node].line_number}:#{index[:node].column_number}" %}
          {% end %}
        {% end %}
        {% index_name = "index_#{table.id}_on_#{index[:columns].join("_and_").id}" %}
        {% replaced = indexes.reject { |existing| existing[:name] == index_name } %}
        {% indexes = replaced + [{name: index_name, columns: index[:columns], unique: index[:unique]}] %}
      {% end %}
      {% for drop in drops %}
        {% if columns.any? { |column| column[:name] == drop[:name] } %}
          {% drop[:node].raise "drop_column :#{drop[:name].id} names a declared column of #{@type}.\nRemediation: remove the field declaration, or remove the drop_column." + "\n  --> #{drop[:node].filename.id}:#{drop[:node].line_number}:#{drop[:node].column_number}" %}
        {% end %}
      {% end %}
      {% primary_key = primary[0] %}

      SUGAR_TABLE = {{ table }}

      # Column metadata read at compile time by changeset params.
      SUGAR_FIELDS = {
        {% for column in columns %}
          {{ column[:name].id }}: {type: {{ column[:type] }}, declared: {{ column[:declared] }}, nullable: {{ column[:nullable] }}, system: {{ column[:system] }}},
        {% end %}
      }

      enum Field
        {% for column in columns %}
          {{ column[:name].camelcase.id }}
        {% end %}
      end

      {% for column in columns %}
        getter {{ column[:name].id }} : {{ column[:type].id }}
      {% end %}

      def initialize(*, {{ columns.map { |column| "@#{column[:name].id} : #{column[:type].id}#{!column[:literal].is_a?(NilLiteral) ? " = #{column[:literal].stringify.id}".id : (column[:nullable] ? " = nil".id : "".id)}" }.join(", ").id }})
      end

      # A copy with the given fields replaced; never persists.
      def with(*, {{ columns.map { |column| "#{column[:name].id} : #{column[:type].id} = @#{column[:name].id}" }.join(", ").id }}) : self
        self.class.new({{ columns.map { |column| "#{column[:name].id}: #{column[:name].id}" }.join(", ").id }})
      end

      # Reads one row selected with `__sugar_select_list`, in declaration order.
      def self.from_row(rows : ::DB::ResultSet) : self
        new({{ columns.map { |column| "#{column[:name].id}: rows.read(#{column[:type].id})" }.join(", ").id }})
      end

      # Declared columns in declaration order; associations are not serialized.
      def to_json(json : ::JSON::Builder) : Nil
        json.object do
          {% for column in columns %}
            json.field {{ column[:name] }}, @{{ column[:name].id }}
          {% end %}
        end
      end

      def self.__sugar_table_name : String
        {{ table }}
      end

      def self.__sugar_quoted_table : String
        {{ "\"#{table.id}\"" }}
      end

      def self.__sugar_primary_key : String
        {{ primary_key }}
      end

      def self.__sugar_select_list : String
        {{ columns.map { |column| "\"#{column[:name].id}\"" }.join(", ") }}
      end

      def self.__sugar_timestamps? : Bool
        {{ !timestamps.empty? }}
      end

      def self.__sugar_not_null_columns : Array(String)
        {{ columns.reject { |column| column[:nullable] || column[:system] }.map(&.[:name]) }} of String
      end

      # NOT NULL columns without a default: an insert must supply them.
      def self.__sugar_required_columns : Array(String)
        {{ columns.reject { |column| column[:nullable] || column[:system] || column[:default] }.map(&.[:name]) }} of String
      end

      def self.__sugar_column(field : Field) : String
        case field
        {% for column in columns %}
        in Field::{{ column[:name].camelcase.id }} then {{ column[:name] }}
        {% end %}
        end
      end

      def __sugar_get(column : String) : ::SugarORM::Value
        case column
        {% for column in columns %}
        when {{ column[:name] }} then @{{ column[:name].id }}
        {% end %}
        else raise ArgumentError.new("#{self.class} has no column '#{column}'")
        end
      end

      def __sugar_primary_value : Int64
        @{{ primary_key.id }}
      end

      def self.__sugar_table : ::SugarORM::Catalog::Table
        ::SugarORM::Catalog::Table.new(
          name: {{ table }},
          columns: [
            {% for column in columns %}
              ::SugarORM::Catalog::Column.new(name: {{ column[:name] }}, sql_type: {{ column[:sql_type] }}, nullable: {{ column[:nullable] }}, default: {{ column[:default] }}, primary: {{ column[:primary] }}, identity: {{ column[:primary] }}, renamed_from: {{ column[:renamed_from] }}),
            {% end %}
          ] of ::SugarORM::Catalog::Column,
          indexes: [
            {% for index in indexes %}
              ::SugarORM::Catalog::Index.new(name: {{ index[:name] }}, columns: {{ index[:columns] }} of String, unique: {{ index[:unique] }}),
            {% end %}
          ] of ::SugarORM::Catalog::Index,
          foreign_keys: [
            {% for key in foreign_keys %}
              ::SugarORM::Catalog::ForeignKey.new(name: {{ key[:name] }}, column: {{ key[:column] }}, references_table: {{ key[:target] }}.__sugar_table_name, references_column: {{ key[:target] }}.__sugar_primary_key),
            {% end %}
          ] of ::SugarORM::Catalog::ForeignKey,
          drops: {{ drops.map(&.[:name]) }} of String,
        )
      end

      {% for association in associations %}
        {% camel = association[:name].camelcase %}
        {% message = "Association '#{association[:name].id}' of #{@type} was not preloaded; using it would run one query per #{@type} (N+1). Remediation: add .preload(:#{association[:name].id}) to the query that loaded this #{@type}, e.g. #{@type}.query.preload(:#{association[:name].id}).find(id)" %}

        # Returned by `#{{ association[:name].id }}` until the association is
        # preloaded. It defines no collection or record methods, so using it
        # fails to compile at the caller's line; the remediation travels in the
        # type's name because macro errors raised while typing a method body
        # lose the caller's location.
        struct {{ camel.id }}NotLoaded(Remediation) < ::SugarORM::NotLoaded
        end

        def {{ association[:name].id }} : {{ camel.id }}NotLoaded(NamedTuple({{ message }}: ::Nil))
          {{ camel.id }}NotLoaded(NamedTuple({{ message }}: ::Nil)).new
        end

        struct ::SugarORM::Loaded(T, L)
          def {{ association[:name].id }}
            \{% if L.keys.map(&.stringify).includes?({{ association[:name] }}) %}
              @loaded[{{ association[:name].id.symbolize }}]
            \{% else %}
              @record.{{ association[:name].id }}
            \{% end %}
          end
        end
      {% end %}

      struct QueryOf(P) < ::SugarORM::Query(::{{ @type }}, P)
        {% signature = columns.map do |column|
             scalar = "::#{column[:scalar].id}"
             ranges = %w(Int32 Int64 Float64 Time).includes?(column[:scalar]) ? ["Range(#{scalar.id}, #{scalar.id})", "Range(#{scalar.id}, ::Nil)", "Range(::Nil, #{scalar.id})"] : [] of Nil
             accepted = [scalar, "Array(#{scalar.id})"] + ranges + (column[:nullable] ? ["::Nil"] : [] of Nil)
             "#{column[:name].id} : #{accepted.join(" | ").id} | ::SugarORM::Unset = ::SugarORM::UNSET"
           end.join(", ") %}

        # Keyword conditions, checked against the columns at compile time: a
        # value, nil (IS NULL), an Array (= ANY) or a Range.
        def where(*, {{ signature.id }}) : self
          __sugar_conditions = [] of ::SugarORM::Condition
          {% for column in columns %}
            __sugar_conditions << ::SugarORM::Condition.column({{ column[:name] }}, {{ column[:name].id }}) unless {{ column[:name].id }}.is_a?(::SugarORM::Unset)
          {% end %}
          __sugar_where(__sugar_conditions)
        end

        def self.where(*, {{ signature.id }})
          new.where({{ columns.map { |column| "#{column[:name].id}: #{column[:name].id}" }.join(", ").id }})
        end

        {% for association in associations %}
          {% camel = association[:name].camelcase %}
          enum Preload{{ camel.id }}
            {{ camel.id }}
          end

          def preload(association : Preload{{ camel.id }})
            {% if association[:kind] == "has_many" %}
              QueryOf.new(@clauses, @preloads.merge({{ association[:name].id }}: ::SugarORM::HasMany(::{{ @type }}, {{ association[:target] }}).new({{ association[:key] }})))
            {% elsif association[:kind] == "has_one" %}
              QueryOf.new(@clauses, @preloads.merge({{ association[:name].id }}: ::SugarORM::HasOne(::{{ @type }}, {{ association[:target] }}).new({{ association[:key] }})))
            {% else %}
              QueryOf.new(@clauses, @preloads.merge({{ association[:name].id }}: ::SugarORM::BelongsTo(::{{ @type }}, {{ association[:target] }}, {{ association[:target] }}{{ association[:optional] ? "?".id : "".id }}).new({{ association[:key] }}, &.{{ association[:key].id }})))
            {% end %}
          end

          def self.preload(association : Preload{{ camel.id }})
            new.preload(association)
          end
        {% end %}
      end

      alias Query = QueryOf(NamedTuple())

      def self.query : Query
        Query.new
      end

      # Permits every non-system field; used by the facade unless the program
      # defines CreateChangeset / UpdateChangeset.
      class DefaultChangeset < ::SugarORM::Changeset(::{{ @type }})
        {% for column in columns %}
          {% unless column[:system] %}
            param {{ column[:name].id }} : {{ column[:declared].id }}
          {% end %}
        {% end %}

        def validate(cs)
          {% for index in indexes %}
            {% if index[:unique] %}
              cs.unique_constraint(:{{ index[:columns][0].id }})
            {% end %}
          {% end %}
        end
      end

      def delete : Bool
        ::SugarORM::Repo.delete(self)
      end

      def delete(db : ::SugarORM::Handle) : Bool
        ::SugarORM::Repo.using(db) { delete }
      end

      macro finished
        {% for association in associations %}
          {% if association[:kind] != "belongs_to" %}
            {% location = "#{association[:node].filename.id}:#{association[:node].line_number}" %}
            \{% target = {{ association[:target] }}.resolve? %}
            \{% fields = target && target.constant(:SUGAR_FIELDS) %}
            \{% unless fields && fields[{{ association[:key] }}] %}
              \{% raise "{{ @type }}: `{{ association[:kind].id }} {{ association[:name].id }} : {{ association[:target] }}` (at {{ location.id }}) expects the column {{ association[:key].id }} on {{ association[:target] }}, which does not declare it.\nRemediation: add `belongs_to {{ owner_key[0..-4].id }} : {{ @type }}` to {{ association[:target] }}'s schema, or pass `foreign_key: :column`." %}
            \{% end %}
          {% end %}
        {% end %}
        __sugar_facade(\{{@type.has_constant?(:CreateChangeset) ? "CreateChangeset".id : "DefaultChangeset".id}}, \{{@type.has_constant?(:UpdateChangeset) ? "UpdateChangeset".id : "DefaultChangeset".id}})
      end
    end

    # Generates the facade from the chosen changesets' params, so a facade call
    # with an unknown keyword or a mistyped value fails at the caller's line.
    # :nodoc:
    macro __sugar_facade(create, update)
      {% keywords = {} of Nil => Nil %}
      {% forwards = {} of Nil => Nil %}
      {% for pair in [{"create", create}, {"update", update}] %}
        {% changeset = pair[1].resolve %}
        {% params = changeset.constants.select(&.starts_with?("SUGAR_PARAM_")).map { |name| changeset.constant(name) } %}
        {% keywords[pair[0]] = params.map { |param| "#{param[0].id} : #{param[1].id} | ::Nil | ::SugarORM::Unset = ::SugarORM::UNSET" }.join(", ") %}
        {% forwards[pair[0]] = params.map { |param| "#{param[0].id}: #{param[0].id}" }.join(", ") %}
      {% end %}
      {% create_alone = keywords["create"].empty? ? "".id : "(*, #{keywords["create"].id})".id %}
      {% create_after = keywords["create"].empty? ? "".id : ", *, #{keywords["create"].id}".id %}
      {% update_alone = keywords["update"].empty? ? "".id : "(*, #{keywords["update"].id})".id %}
      {% update_after = keywords["update"].empty? ? "".id : ", *, #{keywords["update"].id}".id %}
      {% update_forward = forwards["update"].empty? ? "".id : ", #{forwards["update"].id}".id %}

      # Builds {{ create }} and inserts it through the Repo.
      def self.create{{ create_alone }} : ::SugarORM::Changeset(::{{ @type }})
        ::SugarORM::Repo.insert({{ create }}.new({{ forwards["create"].id }}))
      end

      # Like `create`, but returns the stored record or raises SugarORM::Invalid.
      def self.create!{{ create_alone }} : ::{{ @type }}
        changeset = create({{ forwards["create"].id }})
        raise ::SugarORM::Invalid.new(changeset) unless changeset.saved?
        changeset.record
      end

      def self.create(db : ::SugarORM::Handle{{ create_after }}) : ::SugarORM::Changeset(::{{ @type }})
        ::SugarORM::Repo.using(db) { create({{ forwards["create"].id }}) }
      end

      def self.create!(db : ::SugarORM::Handle{{ create_after }}) : ::{{ @type }}
        ::SugarORM::Repo.using(db) { create!({{ forwards["create"].id }}) }
      end

      # Builds {{ update }} from this record and updates it through the Repo.
      def update{{ update_alone }} : ::SugarORM::Changeset(::{{ @type }})
        ::SugarORM::Repo.update({{ update }}.new(self{{ update_forward }}))
      end

      # Like `update`, but returns the stored record or raises SugarORM::Invalid.
      def update!{{ update_alone }} : ::{{ @type }}
        changeset = update({{ forwards["update"].id }})
        raise ::SugarORM::Invalid.new(changeset) unless changeset.saved?
        changeset.record
      end

      def update(db : ::SugarORM::Handle{{ update_after }}) : ::SugarORM::Changeset(::{{ @type }})
        ::SugarORM::Repo.using(db) { update({{ forwards["update"].id }}) }
      end

      def update!(db : ::SugarORM::Handle{{ update_after }}) : ::{{ @type }}
        ::SugarORM::Repo.using(db) { update!({{ forwards["update"].id }}) }
      end
    end

    # Declares a named, chainable query clause on `T::Query`:
    #
    #     scope active { where(archived: false) }
    #     scope larger_than(seats : Int32) { where("seats > ?", seats) }
    macro scope(declaration, &block)
      {% body = block ? block : (declaration.is_a?(Call) ? declaration.block : nil) %}
      {% unless declaration.is_a?(Call) && declaration.receiver.is_a?(Nop) && body.is_a?(Block) && declaration.named_args.is_a?(Nop) && declaration.args.all?(&.is_a?(TypeDeclaration)) %}
        {% declaration.raise "scope expects `scope name { where(...) }` or `scope name(arg : Type) { ... }` with typed arguments." + "\n  --> #{declaration.filename.id}:#{declaration.line_number}:#{declaration.column_number}" %}
      {% end %}
      struct QueryOf(P) < ::SugarORM::Query(::{{ @type }}, P)
        def {{ declaration.name }}({{ declaration.args.splat }})
          {{ body.body }}
        end

        def self.{{ declaration.name }}({{ declaration.args.splat }})
          new.{{ declaration.name }}({{ declaration.args.map(&.var).splat }})
        end
      end
    end
  end
end
