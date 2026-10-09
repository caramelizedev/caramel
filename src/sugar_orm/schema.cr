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
          \{% raise "#{@type} inherits SugarORM::Schema but never declares its table.\n" +
                    "Remediation: add `schema \"table_name\" do ... end` " +
                    "with at least `field id : Int64, primary: true` to #{@type}." %}
        \{% end %}
      end
    end

    {% for name in %w(field timestamps belongs_to has_many has_one index drop_column tenant) %}
      # :nodoc:
      macro {{ name.id }}(*arguments, **options)
        \{% raise "`{{ name.id }}` belongs inside the schema block.\n" +
                  "Remediation: move it into `schema \"table\" do ... end` of #{@type}." %}
      end
    {% end %}

    macro schema(table, &block)
      {% table_at = "\n  --> #{table.filename.id}:" +
                    "#{table.line_number}:#{table.column_number}" %}
      {% unless table.is_a?(StringLiteral) && table =~ /\A[a-z][a-z0-9_]*\z/ %}
        {% problem = "schema expects the table name " +
                     "as a lowercase snake_case string literal.\n" +
                     "Remediation: write it like `schema \"teams\" do ... end`." %}
        {% table.raise problem + table_at %}
      {% end %}
      {% if @type.has_constant?(:SUGAR_TABLE) %}
        {% problem = "#{@type} declares `schema` twice.\n" +
                     "Remediation: keep a single " +
                     "`schema \"#{table.id}\" do ... end` block." %}
        {% table.raise problem + table_at %}
      {% end %}
      {% unless block %}
        {% problem = "schema needs a block.\n" +
                     "Remediation: write `schema #{table} do\n" +
                     "  field id : Int64, primary: true\nend`." %}
        {% table.raise problem + table_at %}
      {% end %}
      {% statements = [block.body] %}
      {% if block.body.is_a?(Expressions) %}
        {% statements = block.body.expressions %}
      {% elsif block.body.is_a?(Nop) %}
        {% statements = [] of Nil %}
      {% end %}
      {% sql_types = {
           "String"  => "text",
           "Int32"   => "integer",
           "Int64"   => "bigint",
           "Bool"    => "boolean",
           "Float64" => "double precision",
           "Time"    => "timestamp with time zone",
         } %}
      {% reserved = %w(
           db with update update! delete query create create! from_row to_json record
           class hash dup inspect to_s initialize self end def if unless while until
           case when in of out do then else elsif begin rescue ensure return yield
           nil true false and or not typeof sizeof alias struct module enum lib fun
           macro include extend require abstract private protected super previous_def
         ) %}
      {% holds_only = "Remediation: a schema block holds only " +
                      "field, timestamps, belongs_to, has_many, has_one, " +
                      "index, drop_column and tenant declarations." %}
      {% owner = @type.name(generic_args: false).stringify.split("::").last %}
      {% owner_key = owner.underscore + "_id" %}
      {% columns = [] of Nil %}
      {% associations = [] of Nil %}
      {% indexes = [] of Nil %}
      {% explicit_indexes = [] of Nil %}
      {% foreign_keys = [] of Nil %}
      {% drops = [] of Nil %}
      {% primary = [] of Nil %}
      {% timestamps = [] of Nil %}
      {% tenants = [] of Nil %}

      {% for statement in statements %}
        {% statement_at = "\n  --> #{statement.filename.id}:" +
                          "#{statement.line_number}:#{statement.column_number}" %}
        {% plain = statement.is_a?(Call) && statement.receiver.is_a?(Nop) %}
        {% unless plain && statement.block.is_a?(Nop) %}
          {% problem = "Unknown schema declaration `#{statement}`.\n" + holds_only %}
          {% statement.raise problem + statement_at %}
        {% end %}
        {% kind = statement.name.stringify %}
        {% named = statement.named_args.is_a?(Nop) ? [] of Nil : statement.named_args %}

        {% if kind == "field" %}
          {% declaration = statement.args[0] %}
          {% unless statement.args.size == 1 && declaration.is_a?(TypeDeclaration) %}
            {% problem = "field expects `field name : Type`.\n" +
                         "Remediation: write it like `field seats : Int32 = 5`, " +
                         "optionally with `primary: true` or `renamed_from: :old_name`." %}
            {% statement.raise problem + statement_at %}
          {% end %}
          {% declaration_at = "\n  --> #{declaration.filename.id}:" +
                              "#{declaration.line_number}:#{declaration.column_number}" %}
          {% name = declaration.var.stringify %}
          {% options = {} of Nil => Nil %}
          {% for argument in named %}
            {% unless %w(primary renamed_from codec).includes?(argument.name.stringify) %}
              {% problem = "Unknown field option '#{argument.name}' " +
                           "on field '#{name.id}'.\n" +
                           "Remediation: fields accept only `primary: true`, " +
                           "`renamed_from: :old_name` and `codec: Codec`." %}
              {% statement.raise problem + statement_at %}
            {% end %}
            {% options[argument.name.stringify] = argument.value %}
          {% end %}
          {% type = declaration.type %}
          {% codec = options["codec"] %}
          {% nullable = false %}
          {% scalar = nil %}
          {% written = nil %}
          {% if type.is_a?(Union) %}
            {% members = type.types.map(&.stringify.gsub(/\A::/, "")) %}
            {% others = type.types.reject { |member| member.stringify =~ /\A(::)?Nil\z/ } %}
            {% if members.size == 2 && others.size == 1 %}
              {% nullable = true %}
              {% written = others[0] %}
              {% scalar = others[0].stringify.gsub(/\A::/, "") %}
            {% end %}
          {% elsif type.is_a?(Path) || (codec && type.is_a?(Generic)) %}
            {% written = type %}
            {% scalar = type.stringify.gsub(/\A::/, "") %}
          {% end %}
          {% unless (codec && scalar) || sql_types[scalar] %}
            {% problem = "Unsupported type `#{type}` for field '#{name.id}'.\n" +
                         "Supported: String, Int32, Int64, Bool, Float64 and Time, " +
                         "each optionally nilable (`String?`).\n" +
                         "Remediation: declare `field #{name.id} : String` " +
                         "(or another supported type), or store the type through a codec: " +
                         "`field #{name.id} : #{type}, codec: SomeCodec`." %}
            {% declaration.raise problem + declaration_at %}
          {% end %}
          {% alias_type = "::#{@type}::SugarType#{name.camelcase.id}" %}
          {% if codec && !declaration.value.is_a?(Nop) %}
            {% problem = "Field '#{name.id}' has codec: #{codec}, so it takes no default.\n" +
                         "Remediation: set the value in a changeset." %}
            {% declaration.raise problem + declaration_at %}
          {% end %}
          {% value = declaration.value %}
          {% default = nil %}
          {% literal = nil %}
          {% integer_type = %w(Int32 Int64).includes?(scalar) %}
          {% number = value.is_a?(NumberLiteral) %}
          {% whole = number && value.kind.stringify =~ /\A:[iu]/ %}
          {% if value.is_a?(Nop) %}
          {% elsif value.is_a?(NilLiteral) %}
            {% unless nullable %}
              {% problem = "Field '#{name.id} : #{type}' cannot default to nil.\n" +
                           "Remediation: make it `#{scalar.id}?` " +
                           "or give a #{scalar.id} literal default." %}
              {% declaration.raise problem + declaration_at %}
            {% end %}
          {% elsif number && (scalar == "Float64" || (integer_type && whole)) %}
            {% digits = value.stringify.gsub(/_?[iuf](8|16|32|64|128)\z/, "") %}
            {% default = digits.gsub(/_/, "") %}
            {% literal = value %}
          {% elsif value.is_a?(StringLiteral) && scalar == "String" %}
            {% default = "'" + value.gsub(/'/, "''") + "'" %}
            {% literal = value %}
          {% elsif value.is_a?(BoolLiteral) && scalar == "Bool" %}
            {% default = value.stringify %}
            {% literal = value %}
          {% else %}
            {% problem = "Default `#{value}` for field '#{name.id} : #{type}' " +
                         "is not a compile-time #{scalar.id} literal.\n" +
                         "Defaults become SQL column defaults, so they must be literals " +
                         "(`5`, `\"x\"`, `true`, `2.5`); Time fields take none.\n" +
                         "Remediation: write a literal default, " +
                         "or drop it and set the value in a changeset." %}
            {% declaration.raise problem + declaration_at %}
          {% end %}
          {% is_primary = false %}
          {% if options.keys.includes?("primary") %}
            {% unless options["primary"].is_a?(BoolLiteral) %}
              {% problem = "primary: takes `true` or `false`.\n" +
                           "Remediation: write " +
                           "`field #{name.id} : Int64, primary: true`." %}
              {% statement.raise problem + statement_at %}
            {% end %}
            {% is_primary = options["primary"] == true %}
          {% end %}
          {% if is_primary %}
            {% unless scalar == "Int64" && !nullable && value.is_a?(Nop) && !codec %}
              {% problem = "The primary key '#{name.id}' must be a non-nilable Int64 " +
                           "without a default (it becomes an identity column).\n" +
                           "Remediation: declare " +
                           "`field #{name.id} : Int64, primary: true`." %}
              {% declaration.raise problem + declaration_at %}
            {% end %}
            {% unless primary.empty? %}
              {% problem = "#{@type} already has the primary key '#{primary[0].id}'.\n" +
                           "Remediation: keep a single `primary: true` field." %}
              {% declaration.raise problem + declaration_at %}
            {% end %}
            {% primary << name %}
          {% end %}
          {% renamed = nil %}
          {% if options.keys.includes?("renamed_from") %}
            {% source = options["renamed_from"] %}
            {% symbol = source.is_a?(SymbolLiteral) || source.is_a?(StringLiteral) %}
            {% old_name = symbol ? source.id.stringify : "" %}
            {% unless old_name =~ /\A[a-z][a-z0-9_]*\z/ && old_name != name %}
              {% problem = "renamed_from: must name the old column as a symbol " +
                           "other than '#{name.id}', like `renamed_from: :email`." %}
              {% statement.raise problem + statement_at %}
            {% end %}
            {% renamed = source.id.stringify %}
          {% end %}
          {% column_type = codec ? alias_type : "::#{scalar.id}" %}
          {% columns << {
               node:         declaration,
               name:         name,
               declared:     nullable ? "#{scalar.id}?" : scalar,
               type:         nullable ? "#{column_type.id} | ::Nil" : column_type,
               scalar:       scalar,
               nullable:     nullable,
               sql_type:     codec ? nil : sql_types[scalar],
               default:      default,
               literal:      literal,
               primary:      is_primary,
               system:       is_primary,
               renamed_from: renamed,
               codec:        codec,
               written:      written,
             } %}

        {% elsif kind == "timestamps" %}
          {% unless statement.args.empty? && named.empty? %}
            {% problem = "timestamps takes no arguments; " +
                         "it adds created_at and updated_at." %}
            {% statement.raise problem + statement_at %}
          {% end %}
          {% unless timestamps.empty? %}
            {% problem = "timestamps is declared twice.\n" +
                         "Remediation: keep one `timestamps`." %}
            {% statement.raise problem + statement_at %}
          {% end %}
          {% timestamps << true %}
          {% for stamp in %w(created_at updated_at) %}
            {% columns << {
                 node:         statement,
                 name:         stamp,
                 declared:     "Time",
                 type:         "::Time",
                 scalar:       "Time",
                 nullable:     false,
                 sql_type:     "timestamp with time zone",
                 default:      "CURRENT_TIMESTAMP",
                 literal:      nil,
                 primary:      false,
                 system:       true,
                 renamed_from: nil,
                 codec:        nil,
                 written:      nil,
               } %}
          {% end %}

        {% elsif %w(belongs_to has_many has_one tenant).includes?(kind) %}
          {% if kind == "tenant" && !::SugarORM.has_constant?("Tenancy") %}
            {% problem = "tenant needs require \"caramel/tenancy\".\n" +
                         "Remediation: add it after require \"caramel\" " +
                         "in config/application.cr." %}
            {% statement.raise problem + statement_at %}
          {% end %}
          {% declaration = statement.args[0] %}
          {% typed = statement.args.size == 1 && declaration.is_a?(TypeDeclaration) %}
          {% unless typed && declaration.value.is_a?(Nop) %}
            {% example = kind == "has_many" ? "users : User" : "team : Team" %}
            {% example = kind == "tenant" ? "account : Account" : example %}
            {% problem = "#{kind.id} expects `#{kind.id} name : Type`, " +
                         "like `#{kind.id} #{example.id}`." %}
            {% statement.raise problem + statement_at %}
          {% end %}
          {% if kind == "tenant" && !tenants.empty? %}
            {% problem = "tenant is declared twice.\n" +
                         "Remediation: keep one tenant name : Type." %}
            {% statement.raise problem + statement_at %}
          {% end %}
          {% declaration_at = "\n  --> #{declaration.filename.id}:" +
                              "#{declaration.line_number}:#{declaration.column_number}" %}
          {% name = declaration.var.stringify %}
          {% target = declaration.type %}
          {% optional = false %}
          {% if target.is_a?(Union) && kind == "belongs_to" %}
            {% others = target.types.reject do |member|
                 member.stringify.gsub(/\A::/, "") == "Nil"
               end %}
            {% if target.types.size == 2 && others.size == 1 %}
              {% optional = true %}
              {% target = others[0] %}
            {% end %}
          {% end %}
          {% unless target.is_a?(Path) %}
            {% nilable = kind == "belongs_to" ? ", optionally nilable (`User?`)" : "" %}
            {% problem = "#{kind.id} '#{name.id}' must name one schema type#{nilable.id}, " +
                         "not `#{declaration.type}`." %}
            {% declaration.raise problem + declaration_at %}
          {% end %}
          {% key = nil %}
          {% for argument in named %}
            {% option = argument.value %}
            {% symbol = option.is_a?(SymbolLiteral) || option.is_a?(StringLiteral) %}
            {% keyed = argument.name.stringify == "foreign_key" && kind.starts_with?("has_") %}
            {% unless keyed && symbol && option.id.stringify =~ /\A[a-z][a-z0-9_]*\z/ %}
              {% remedy = "the only option is `foreign_key: :column`" %}
              {% if kind == "belongs_to" || kind == "tenant" %}
                {% remedy = "#{kind.id} takes no options; " +
                            "its column is `#{name.id}_id`" %}
              {% end %}
              {% problem = "Unknown #{kind.id} option '#{argument.name}'.\n" +
                           "Remediation: #{remedy.id}." %}
              {% statement.raise problem + statement_at %}
            {% end %}
            {% key = argument.value.id.stringify %}
          {% end %}
          {% if kind == "belongs_to" || kind == "tenant" %}
            {% key = name + "_id" %}
            {% tenant_key = kind == "tenant" %}
            {% columns << {
                 node:         declaration,
                 name:         key,
                 declared:     optional ? "Int64?" : "Int64",
                 type:         optional ? "::Int64 | ::Nil" : "::Int64",
                 scalar:       "Int64",
                 nullable:     optional,
                 sql_type:     "bigint",
                 default:      nil,
                 literal:      nil,
                 primary:      false,
                 system:       tenant_key,
                 renamed_from: nil,
                 codec:        nil,
                 written:      nil,
               } %}
            {% foreign_keys << {
                 name:   "fk_#{table.id}_#{key.id}",
                 column: key,
                 target: target,
                 tenant: tenant_key,
               } %}
            {% if tenant_key %}
              {% tenants << {node: declaration, name: name, column: key, target: target} %}
            {% else %}
              {% indexes << {
                   name:    "index_#{table.id}_on_#{key.id}",
                   columns: [key],
                   unique:  false,
                   tenant:  false,
                 } %}
            {% end %}
          {% else %}
            {% key = key || owner_key %}
          {% end %}
          {% associations << {
               node:     declaration,
               name:     name,
               kind:     kind == "tenant" ? "belongs_to" : kind,
               target:   target,
               key:      key,
               optional: optional,
             } %}

        {% elsif kind == "index" %}
          {% symbols = statement.args.all? do |argument|
               argument.is_a?(SymbolLiteral) || argument.is_a?(StringLiteral)
             end %}
          {% unless !statement.args.empty? && symbols %}
            {% problem = "index expects column symbols, " +
                         "like `index :name, unique: true`." %}
            {% statement.raise problem + statement_at %}
          {% end %}
          {% unique = false %}
          {% for argument in named %}
            {% unique_option = argument.name.stringify == "unique" %}
            {% unless unique_option && argument.value.is_a?(BoolLiteral) %}
              {% problem = "Unknown index option '#{argument.name}'.\n" +
                           "Remediation: the only option is `unique: true`." %}
              {% statement.raise problem + statement_at %}
            {% end %}
            {% unique = argument.value %}
          {% end %}
          {% explicit_indexes << {
               node:    statement,
               columns: statement.args.map(&.id.stringify),
               unique:  unique,
             } %}

        {% elsif kind == "drop_column" %}
          {% dropped = statement.args[0] %}
          {% single = statement.args.size == 1 && named.empty? %}
          {% symbol = dropped.is_a?(SymbolLiteral) || dropped.is_a?(StringLiteral) %}
          {% unless single && symbol && dropped.id.stringify =~ /\A[a-z][a-z0-9_]*\z/ %}
            {% problem = "drop_column expects one column symbol, " +
                         "like `drop_column :legacy_code`." %}
            {% statement.raise problem + statement_at %}
          {% end %}
          {% drops << {node: statement, name: statement.args[0].id.stringify} %}

        {% else %}
          {% problem = "Unknown schema declaration '#{kind.id}'.\n" + holds_only %}
          {% statement.raise problem + statement_at %}
        {% end %}
      {% end %}

      {% if primary.empty? %}
        {% problem = "#{@type} has no primary key.\n" +
                     "Remediation: add `field id : Int64, primary: true` " +
                     "to the schema block of #{@type}." %}
        {% table.raise problem + table_at %}
      {% end %}
      {% tenant = tenants.empty? ? nil : tenants[0] %}
      {% if tenant %}
        {% tenant_column = tenant[:column] %}
        {% tenant_index = {
             name:    "index_#{table.id}_on_#{tenant_column.id}_and_#{primary[0].id}",
             columns: [tenant_column, primary[0]],
             unique:  true,
             tenant:  true,
           } %}
        {% indexes = [tenant_index] + indexes %}
      {% end %}
      {% names = [] of Nil %}
      {% for column in columns %}
        {% node = column[:node] %}
        {% node_at = "\n  --> #{node.filename.id}:" +
                     "#{node.line_number}:#{node.column_number}" %}
        {% unless column[:name] =~ /\A[a-z][a-z0-9_]*\z/ %}
          {% problem = "Column name '#{column[:name].id}' must be lowercase snake_case." %}
          {% node.raise problem + node_at %}
        {% end %}
        {% if names.includes?(column[:name]) %}
          {% problem = "#{@type} declares the column '#{column[:name].id}' twice.\n" +
                       "Remediation: remove the duplicate " +
                       "(timestamps adds created_at/updated_at; " +
                       "belongs_to x and tenant x add x_id)." %}
          {% node.raise problem + node_at %}
        {% end %}
        {% if reserved.includes?(column[:name]) %}
          {% problem = "'#{column[:name].id}' is reserved by SugarORM or Crystal " +
                       "and cannot be a field name.\n" +
                       "Remediation: rename the field " +
                       "(use `renamed_from:` to keep existing data)." %}
          {% node.raise problem + node_at %}
        {% end %}
        {% names << column[:name] %}
      {% end %}
      {% for association in associations %}
        {% name = association[:name] %}
        {% node = association[:node] %}
        {% if names.includes?(name) || reserved.includes?(name) %}
          {% problem = "Association '#{name.id}' " +
                       "collides with a column or reserved name.\n" +
                       "Remediation: rename the association." %}
          {% node_at = "\n  --> #{node.filename.id}:" +
                       "#{node.line_number}:#{node.column_number}" %}
          {% node.raise problem + node_at %}
        {% end %}
        {% names << name %}
      {% end %}
      {% for index in explicit_indexes %}
        {% node = index[:node] %}
        {% for column in index[:columns] %}
          {% unless columns.any? { |candidate| candidate[:name] == column } %}
            {% problem = "index references '#{column.id}', " +
                         "which is not a column of #{@type}.\n" +
                         "Columns: #{columns.map(&.[:name]).join(", ").id}" %}
            {% node_at = "\n  --> #{node.filename.id}:" +
                         "#{node.line_number}:#{node.column_number}" %}
            {% node.raise problem + node_at %}
          {% end %}
        {% end %}
        {% index_name = "index_#{table.id}_on_#{index[:columns].join("_and_").id}" %}
        {% replaced = indexes.reject { |existing| existing[:name] == index_name } %}
        {% indexed = index[:columns] %}
        {% if tenant && index[:unique] && !indexed.includes?(tenant[:column]) %}
          {% indexed = indexed + [tenant[:column]] %}
        {% end %}
        {% entry = {name: index_name, columns: indexed, unique: index[:unique], tenant: false} %}
        {% indexes = replaced + [entry] %}
      {% end %}
      {% for drop in drops %}
        {% if columns.any? { |column| column[:name] == drop[:name] } %}
          {% problem = "drop_column :#{drop[:name].id} " +
                       "names a declared column of #{@type}.\n" +
                       "Remediation: remove the field declaration, " +
                       "or remove the drop_column." %}
          {% node = drop[:node] %}
          {% node_at = "\n  --> #{node.filename.id}:" +
                       "#{node.line_number}:#{node.column_number}" %}
          {% node.raise problem + node_at %}
        {% end %}
      {% end %}
      {% primary_key = primary[0] %}

      SUGAR_TABLE = {{ table }}

      # Column metadata read at compile time by changeset params.
      SUGAR_FIELDS = {
        {% for column in columns %}
          {{ column[:name].id }}: {
            type:     {{ column[:type] }},
            declared: {{ column[:declared] }},
            nullable: {{ column[:nullable] }},
            system:   {{ column[:system] }},
          },
        {% end %}
      }

      {% if tenant %}
        # The column that names each row's tenant.
        SUGAR_TENANT = {{ tenant[:column] }}

        def self.__sugar_tenant_column : String
          {{ tenant[:column] }}
        end

        # The tenant id statements are scoped to; nil inside
        # Caramel::Tenancy.without.
        def self.__sugar_tenant_scope : Int64?
          ::SugarORM::Tenancy.scope({{ @type.stringify }})
        end

        # The tenant id a new row belongs to.
        def self.__sugar_tenant_stamp : Int64
          ::SugarORM::Tenancy.stamp({{ @type.stringify }})
        end
      {% end %}

      enum Field
        {% for column in columns %}
          {{ column[:name].camelcase.id }}
        {% end %}
      end

      {% for column in columns %}
        {% if column[:codec] %}
          alias SugarType{{ column[:name].camelcase.id }} = {{ column[:written] }}
        {% end %}
        getter {{ column[:name].id }} : {{ column[:type].id }}
      {% end %}

      {% parameters = columns.map do |column|
           literal = column[:literal]
           fallback = column[:nullable] ? " = nil" : ""
           fallback = literal.is_a?(NilLiteral) ? fallback : " = #{literal.stringify.id}"
           "@#{column[:name].id} : #{column[:type].id}#{fallback.id}"
         end %}
      def initialize(*, {{ parameters.join(", ").id }})
      end

      {% replacements = columns.map do |column|
           "#{column[:name].id} : #{column[:type].id} = @#{column[:name].id}"
         end %}
      {% forwarded = columns.map { |column| "#{column[:name].id}: #{column[:name].id}" } %}
      # A copy with the given fields replaced; never persists.
      def with(*, {{ replacements.join(", ").id }}) : self
        self.class.new({{ forwarded.join(", ").id }})
      end

      {% readers = columns.map do |column|
           key = column[:name].id
           if column[:codec] && column[:nullable]
             "#{key}: rows.read(::String | ::Nil).try { |text| #{column[:codec]}.decode(text) }"
           elsif column[:codec]
             "#{key}: #{column[:codec]}.decode(rows.read(::String))"
           else
             "#{key}: rows.read(#{column[:type].id})"
           end
         end %}
      # Reads one row selected with `__sugar_select_list`, in declaration order.
      def self.from_row(rows : ::DB::ResultSet) : self
        new({{ readers.join(", ").id }})
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

      {% selected = columns.map do |column|
           column[:codec] ? "\"#{column[:name].id}\"::text" : "\"#{column[:name].id}\""
         end %}
      def self.__sugar_select_list : String
        {{ selected.join(", ") }}
      end

      def self.__sugar_timestamps? : Bool
        {{ !timestamps.empty? }}
      end

      {% not_null = columns.reject { |column| column[:nullable] || column[:system] } %}
      def self.__sugar_not_null_columns : Array(String)
        {{ not_null.map(&.[:name]) }} of String
      end

      # NOT NULL columns without a default: an insert must supply them.
      def self.__sugar_required_columns : Array(String)
        {{ not_null.reject(&.[:default]).map(&.[:name]) }} of String
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
        {% if column[:codec] %}
        when {{ column[:name] }}
          self.class.__sugar_encode_{{ column[:name].id }}(@{{ column[:name].id }})
        {% else %}
        when {{ column[:name] }} then @{{ column[:name].id }}
        {% end %}
        {% end %}
        else raise ArgumentError.new("#{self.class} has no column '#{column}'")
        end
      end

      {% for column in columns %}
        {% if column[:codec] %}
          # :nodoc:
          def self.__sugar_encode_{{ column[:name].id }}(
            value : ::{{ @type }}::SugarType{{ column[:name].camelcase.id }} | ::Nil
          ) : ::String?
            value.nil? ? nil : {{ column[:codec] }}.encode(value)
          end
        {% else %}
          # :nodoc:
          def self.__sugar_encode_{{ column[:name].id }}(value)
            value
          end
        {% end %}
      {% end %}

      # :nodoc:
      # Encodes a candidate value for a column the way a changeset stores it:
      # codec columns encode a value of their type, and anything else passes.
      def self.__sugar_encode_candidate(column : String, value)
        case column
        {% for column in columns %}
        {% if column[:codec] %}
        when {{ column[:name] }}
          if value.is_a?(::{{ @type }}::SugarType{{ column[:name].camelcase.id }})
            {{ column[:codec] }}.encode(value)
          else
            value
          end
        {% end %}
        {% end %}
        else value
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
              ::SugarORM::Catalog::Column.new(
                name: {{ column[:name] }},
                {% if column[:codec] %}
                  sql_type: ::SugarORM::Codec.checked_sql_type({{ column[:codec] }}.sql_type),
                  nullable: {{ column[:nullable] }},
                  default: nil,
                {% else %}
                  sql_type: {{ column[:sql_type] }},
                  nullable: {{ column[:nullable] }},
                  default: {{ column[:default] }},
                {% end %}
                primary: {{ column[:primary] }},
                identity: {{ column[:primary] }},
                renamed_from: {{ column[:renamed_from] }},
              ),
            {% end %}
          ] of ::SugarORM::Catalog::Column,
          indexes: [
            {% for index in indexes %}
              ::SugarORM::Catalog::Index.new(
                name: {{ index[:name] }},
                columns: {{ index[:columns] }} of String,
                unique: {{ index[:unique] }},
              ),
            {% end %}
          ] of ::SugarORM::Catalog::Index,
          foreign_keys: __sugar_foreign_keys,
          drops: {{ drops.map(&.[:name]) }} of String,
        )
      end

      {% for association in associations %}
        {% camel = association[:name].camelcase %}
        {% link = association[:name].id %}
        {% message = "Association '#{link}' of #{@type} was not preloaded; " +
                     "using it would run one query per #{@type} (N+1). " +
                     "Remediation: add .preload(:#{link}) " +
                     "to the query that loaded this #{@type}, " +
                     "e.g. #{@type}.query.preload(:#{link}).find(id)" %}
        {% sentinel = "#{camel.id}NotLoaded".id %}

        # Returned by `#{{ association[:name].id }}` until the association is
        # preloaded. It defines no collection or record methods, so using it
        # fails to compile at the caller's line; the remediation travels in the
        # type's name because macro errors raised while typing a method body
        # lose the caller's location.
        struct {{ camel.id }}NotLoaded(Remediation) < ::SugarORM::NotLoaded
        end

        def {{ association[:name].id }} : {{ sentinel }}(NamedTuple({{ message }}: ::Nil))
          {{ sentinel }}(NamedTuple({{ message }}: ::Nil)).new
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
             closed = "Range(#{scalar.id}, #{scalar.id})"
             open_end = "Range(#{scalar.id}, ::Nil)"
             open_start = "Range(::Nil, #{scalar.id})"
             ranged = %w(Int32 Int64 Float64 Time).includes?(column[:scalar])
             ranges = ranged ? [closed, open_end, open_start] : [] of Nil
             nilable = column[:nullable] ? ["::Nil"] : [] of Nil
             accepted = [scalar, "Array(#{scalar.id})"] + ranges + nilable
             if column[:codec]
               accepted = ["::#{@type}::SugarType#{column[:name].camelcase.id}"] + nilable
             end
             unset = "::SugarORM::Unset = ::SugarORM::UNSET"
             "#{column[:name].id} : #{accepted.join(" | ").id} | #{unset.id}"
           end.join(", ") %}

        # Keyword conditions, checked against the columns at compile time: a
        # value, nil (IS NULL), an Array (= ANY) or a Range.
        def where(*, {{ signature.id }}) : self
          __sugar_conditions = [] of ::SugarORM::Condition
          {% for column in columns %}
            unless {{ column[:name].id }}.is_a?(::SugarORM::Unset)
              __sugar_conditions << ::SugarORM::Condition.column(
                {{ column[:name] }}, ::{{ @type }}.__sugar_encode_{{ column[:name].id }}(
                  {{ column[:name].id }}
                )
              )
            end
          {% end %}
          __sugar_where(__sugar_conditions)
        end

        def self.where(*, {{ signature.id }})
          new.where({{ forwarded.join(", ").id }})
        end

        {% for association in associations %}
          {% camel = association[:name].camelcase %}
          {% preloaded = association[:target] %}
          {% foreign_key = association[:key] %}
          {% model = "::#{@type}" %}
          enum Preload{{ camel.id }}
            {{ camel.id }}
          end

          def preload(association : Preload{{ camel.id }})
            {% if association[:kind] == "has_many" %}
              {% loader = "::SugarORM::HasMany(#{model.id}, #{preloaded})" +
                          ".new(#{foreign_key})" %}
            {% elsif association[:kind] == "has_one" %}
              {% loader = "::SugarORM::HasOne(#{model.id}, #{preloaded})" +
                          ".new(#{foreign_key})" %}
            {% else %}
              {% value = association[:optional] ? "#{preloaded}?" : "#{preloaded}" %}
              {% loader = "::SugarORM::BelongsTo(#{model.id}, #{preloaded}, #{value.id})" +
                          ".new(#{foreign_key}, &.#{foreign_key.id})" %}
            {% end %}
            QueryOf.new(
              @clauses,
              @preloads.merge({{ association[:name].id }}: {{ loader.id }})
            )
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
            {% if index[:unique] && !index[:tenant] %}
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
            {% node = association[:node] %}
            {% target = association[:target] %}
            {% written = "#{association[:kind].id} #{association[:name].id}" %}
            {% problem = "#{@type}: `#{written.id} : #{target}` " +
                         "(at #{node.filename.id}:#{node.line_number}) " +
                         "expects the column #{association[:key].id} on #{target}, " +
                         "which does not declare it.\n" +
                         "Remediation: add " +
                         "`belongs_to #{owner_key[0..-4].id} : #{@type}` " +
                         "to #{target}'s schema, or pass `foreign_key: :column`." %}
            \{% target = {{ association[:target] }}.resolve? %}
            \{% fields = target && target.constant(:SUGAR_FIELDS) %}
            \{% unless fields && fields[{{ association[:key] }}] %}
              \{% raise {{ problem }} %}
            \{% end %}
          {% end %}
        {% end %}
        {% if tenant %}
          {% node = tenant[:node] %}
          {% written = "tenant #{tenant[:name].id} : #{tenant[:target]}" %}
          {% at = " (at #{node.filename.id}:#{node.line_number})" %}
          {% subject = "#{@type}: #{written.id}#{at.id}" %}
          {% unschema = subject + " must name a SugarORM schema." %}
          {% nested = subject + " names a tenanted schema; " +
                      "the tenant cannot have a tenant itself." %}
          \{% t = {{ tenant[:target] }}.resolve? %}
          \{% unless t && t < ::SugarORM::Schema %}
            \{% raise {{ unschema }} %}
          \{% end %}
          \{% if t.has_constant?(:SUGAR_TENANT) %}
            \{% raise {{ nested }} %}
          \{% end %}
          \{% tenancy = ::SugarORM::Tenancy %}
          \{% declared = tenancy.has_constant?(:SCHEMA) && tenancy.constant(:SCHEMA) %}
          \{% if declared && t.name.stringify != declared %}
            \{% raise {{ subject }} + " names #{t}, but the routes declare " +
                      "#{declared.id} as the tenant.\nRemediation: name #{declared.id} here." %}
          \{% end %}
        {% end %}
        {% tenant_column = tenant ? tenant[:column] : nil %}
        # The table's foreign keys. A key from a tenanted schema to another
        # tenanted one also matches the tenant column, so a row can only
        # reference a row of its own tenant.
        def self.__sugar_foreign_keys : Array(::SugarORM::Catalog::ForeignKey)
          [
            {% for key in foreign_keys %}
              {% target = key[:target] %}
              {% if tenant && !key[:tenant] %}
                \{% composite = {{ target }}.resolve.has_constant?(:SUGAR_TENANT) %}
              {% else %}
                \{% composite = false %}
              {% end %}
              ::SugarORM::Catalog::ForeignKey.new(
                name: {{ key[:name] }},
                references_table: {{ target }}.__sugar_table_name,
                \{% if composite %}
                  columns: [{{ key[:column] }}, {{ tenant_column }}],
                  references_columns: [
                    {{ target }}.__sugar_primary_key,
                    {{ target }}.__sugar_tenant_column,
                  ],
                \{% else %}
                  columns: [{{ key[:column] }}],
                  references_columns: [{{ target }}.__sugar_primary_key],
                \{% end %}
              ),
            {% end %}
          ] of ::SugarORM::Catalog::ForeignKey
        end
        \{% create = @type.has_constant?(:CreateChangeset) %}
        \{% update = @type.has_constant?(:UpdateChangeset) %}
        __sugar_facade(
          \{{ create ? "CreateChangeset".id : "DefaultChangeset".id }},
          \{{ update ? "UpdateChangeset".id : "DefaultChangeset".id }},
        )
      end
    end

    # Generates the facade from the chosen changesets' params, so a facade call
    # with an unknown keyword or a mistyped value fails at the caller's line.
    # :nodoc:
    macro __sugar_facade(create, update)
      {% keywords = {} of Nil => Nil %}
      {% forwards = {} of Nil => Nil %}
      {% unset = " | ::Nil | ::SugarORM::Unset = ::SugarORM::UNSET" %}
      {% for pair in [{"create", create}, {"update", update}] %}
        {% changeset = pair[1].resolve %}
        {% names = changeset.constants.select(&.starts_with?("SUGAR_PARAM_")) %}
        {% params = names.map { |name| changeset.constant(name) } %}
        {% typed = params.map { |param| "#{param[0].id} : #{param[1].id}" + unset } %}
        {% named = params.map { |param| "#{param[0].id}: #{param[0].id}" } %}
        {% keywords[pair[0]] = typed.join(", ") %}
        {% forwards[pair[0]] = named.join(", ") %}
      {% end %}
      {% creating = keywords["create"] %}
      {% updating = keywords["update"] %}
      {% forwarding = forwards["update"] %}
      {% create_alone = creating.empty? ? "".id : "(*, #{creating.id})".id %}
      {% create_after = creating.empty? ? "".id : ", *, #{creating.id}".id %}
      {% update_alone = updating.empty? ? "".id : "(*, #{updating.id})".id %}
      {% update_after = updating.empty? ? "".id : ", *, #{updating.id}".id %}
      {% update_forward = forwarding.empty? ? "".id : ", #{forwarding.id}".id %}
      {% changeset_type = "::SugarORM::Changeset(::#{@type})".id %}

      # Builds {{ create }} and inserts it through the Repo.
      def self.create{{ create_alone }} : {{ changeset_type }}
        ::SugarORM::Repo.insert({{ create }}.new({{ forwards["create"].id }}))
      end

      # Like `create`, but returns the stored record or raises SugarORM::Invalid.
      def self.create!{{ create_alone }} : ::{{ @type }}
        changeset = create({{ forwards["create"].id }})
        raise ::SugarORM::Invalid.new(changeset) unless changeset.saved?
        changeset.record
      end

      def self.create(db : ::SugarORM::Handle{{ create_after }}) : {{ changeset_type }}
        ::SugarORM::Repo.using(db) { create({{ forwards["create"].id }}) }
      end

      def self.create!(db : ::SugarORM::Handle{{ create_after }}) : ::{{ @type }}
        ::SugarORM::Repo.using(db) { create!({{ forwards["create"].id }}) }
      end

      # Builds {{ update }} from this record and updates it through the Repo.
      def update{{ update_alone }} : {{ changeset_type }}
        ::SugarORM::Repo.update({{ update }}.new(self{{ update_forward }}))
      end

      # Like `update`, but returns the stored record or raises SugarORM::Invalid.
      def update!{{ update_alone }} : ::{{ @type }}
        changeset = update({{ forwards["update"].id }})
        raise ::SugarORM::Invalid.new(changeset) unless changeset.saved?
        changeset.record
      end

      def update(db : ::SugarORM::Handle{{ update_after }}) : {{ changeset_type }}
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
      {% plain = declaration.is_a?(Call) && declaration.receiver.is_a?(Nop) %}
      {% typed = plain && declaration.args.all?(&.is_a?(TypeDeclaration)) %}
      {% unless typed && body.is_a?(Block) && declaration.named_args.is_a?(Nop) %}
        {% problem = "scope expects `scope name { where(...) }` " +
                     "or `scope name(arg : Type) { ... }` with typed arguments." %}
        {% declaration_at = "\n  --> #{declaration.filename.id}:" +
                            "#{declaration.line_number}:#{declaration.column_number}" %}
        {% declaration.raise problem + declaration_at %}
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
