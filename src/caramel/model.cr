require "db"

module Caramel
  # A deliberately small typed persistence layer over an already configured
  # crystal-db pool. Models never open a URL and never alter database schema.
  abstract class Model
    class ConfigurationError < Exception
    end

    record Condition, sql : String, values : Array(DB::Any)

    # The application owns this one pool. Configure it during boot, after the
    # transport-aware Caramel::Database has been opened:
    #
    #   Caramel::Model.database = db
    # Crystal class variables have separate storage for subclasses. A module
    # keeps every model on the single application pool configured at boot.
    module Pool
      class_property database : DB::Database?
    end

    def self.database=(database : DB::Database) : DB::Database
      Caramel::Model::Pool.database = database
    end

    def self.database : DB::Database
      Caramel::Model::Pool.database || raise ConfigurationError.new("Caramel::Model.database has not been configured")
    end

    # SQL source identifiers are generated from declarations and always quoted.
    # Values are passed separately to crystal-db as bind parameters.
    def self.__caramel_quote_identifier(identifier : String) : String
      unless identifier =~ /\A[a-zA-Z_][a-zA-Z0-9_]*\z/
        raise ArgumentError.new("invalid SQL identifier")
      end
      "\"#{identifier}\""
    end

    @__caramel_persisted : Bool = false
    @__caramel_deleted : Bool = false
    @__caramel_errors : Hash(String, Array(String)) = {} of String => Array(String)

    def errors : Hash(String, Array(String))
      @__caramel_errors
    end

    def __caramel_persisted? : Bool
      @__caramel_persisted
    end

    def __caramel_deleted? : Bool
      @__caramel_deleted
    end

    def __caramel_mark_persisted : Nil
      @__caramel_persisted = true
      @__caramel_deleted = false
    end

    def __caramel_mark_deleted : Nil
      @__caramel_deleted = true
    end

    # Declare a model table. Symbols and identifier-like calls are intentionally
    # the only useful inputs; the generated SQL still passes through the quote
    # helper above.
    macro table(name)
      {% table_name = "#{name.id}" %}
      TABLE_NAME = {{table_name}}
    end

    # Declare a scalar persisted field. The supported set mirrors DB::Any and
    # accepts a single nullable union (for example String?).
    macro field(declaration, **options)
      {% for option in options.keys %}
        {% unless option == :primary %}
          {% raise "unknown Caramel::Model field option: #{option}" %}
        {% end %}
      {% end %}
      {% field_name = declaration.var %}
      {% field_name_text = "#{declaration.var.id}" %}
      {% declared_type = declaration.type.resolve %}
      {% nullable = false %}
      {% scalar_type = declared_type %}
      {% if declared_type.union? %}
        {% nullable_members = declared_type.union_types.reject { |member| member.id.stringify == "Nil" } %}
        {% if nullable_members.size != 1 || declared_type.union_types.size != 2 %}
          {% raise "#{field_name_text} must use one supported scalar type, optionally unioned with Nil" %}
        {% end %}
        {% nullable = true %}
        {% scalar_type = nullable_members.first %}
      {% end %}
      {% supported = ["String", "Int32", "Int64", "Bool", "Float64", "Time"] %}
      {% unless supported.includes?(scalar_type.id.stringify) %}
        {% raise "unsupported Caramel::Model field type for #{field_name_text}: #{declaration.type.stringify}" %}
      {% end %}
      {% primary = options[:primary] == true %}
      {% if primary && (!nullable || scalar_type.id.stringify != "Int64") %}
        {% raise "primary Caramel::Model field #{field_name_text} must be Int64?" %}
      {% end %}

      {% if nullable || primary %}
        @{{field_name}} : {{declaration.type}} = nil
      {% elsif scalar_type.id.stringify == "String" %}
        @{{field_name}} : {{declaration.type}} = ""
      {% elsif scalar_type.id.stringify == "Int32" %}
        @{{field_name}} : {{declaration.type}} = 0
      {% elsif scalar_type.id.stringify == "Int64" %}
        @{{field_name}} : {{declaration.type}} = 0_i64
      {% elsif scalar_type.id.stringify == "Bool" %}
        @{{field_name}} : {{declaration.type}} = false
      {% elsif scalar_type.id.stringify == "Float64" %}
        @{{field_name}} : {{declaration.type}} = 0.0
      {% elsif scalar_type.id.stringify == "Time" %}
        @{{field_name}} : {{declaration.type}} = Time.utc
      {% end %}
      {% if primary %}
        getter {{field_name}} : {{declaration.type}}
      {% else %}
        property {{field_name}} : {{declaration.type}}
      {% end %}
      FIELD_{{declaration.var.id.upcase}} = true
      {% if primary %}
        PRIMARY_KEY = :{{declaration.var.id}}
      {% end %}

      def self.__caramel_condition_{{field_name}}(value : {{scalar_type}} | Nil) : Condition
        if value.nil?
          Condition.new(__caramel_quote_identifier({{field_name_text}}) + " IS NULL", [] of DB::Any)
        else
          Condition.new(__caramel_quote_identifier({{field_name_text}}) + " = ?", [value.not_nil!] of DB::Any)
        end
      end
    end

    # Add the two system-managed UTC timestamp fields. They have getters only;
    # callers change ordinary declared fields explicitly before save.
    macro timestamps
      @created_at : Time? = nil
      @updated_at : Time? = nil
      getter created_at : Time?
      getter updated_at : Time?
      FIELD_CREATED_AT   = true
      FIELD_UPDATED_AT   = true
      TIMESTAMPS_ENABLED = true

      def self.__caramel_condition_created_at(value : Time? | Nil) : Condition
        if value.nil?
          Condition.new(__caramel_quote_identifier("created_at") + " IS NULL", [] of DB::Any)
        else
          Condition.new(__caramel_quote_identifier("created_at") + " = ?", [value.not_nil!] of DB::Any)
        end
      end

      def self.__caramel_condition_updated_at(value : Time? | Nil) : Condition
        if value.nil?
          Condition.new(__caramel_quote_identifier("updated_at") + " IS NULL", [] of DB::Any)
        else
          Condition.new(__caramel_quote_identifier("updated_at") + " = ?", [value.not_nil!] of DB::Any)
        end
      end
    end

    # Currently the first workflow needs presence validation only. Keeping the
    # declaration as a macro makes invalid field names fail at compile time.
    macro validates(field, **options)
      {% for option in options.keys %}
        {% unless option == :presence %}
          {% raise "unknown Caramel::Model validation option: #{option}" %}
        {% end %}
      {% end %}
      {% field_name_text = "#{field.id}" %}
      {% field_constant = "FIELD_#{field.id.upcase}".id %}
      {% unless @type.constant(field_constant) %}
        {% raise "unknown Caramel::Model validation field: #{field_name_text}" %}
      {% end %}
      {% unless options[:presence] == true %}
        {% raise "only presence: true validation is supported for now" %}
      {% end %}
      VALIDATE_{{field.id.upcase}}_PRESENCE = true
    end

    # These macros run in generated concrete methods, where @type is the
    # concrete model and instance_vars includes inherited declarations.
    macro __caramel_initialize_body(attributes)
      @__caramel_persisted = false
      @__caramel_deleted = false
      @__caramel_errors.clear
      {% for ivar in @type.instance_vars %}
        {% if @type.constant("FIELD_#{ivar.name.id.upcase}".id) %}
          {% if @type.constant(:TIMESTAMPS_ENABLED) == true && (ivar.name == :created_at || ivar.name == :updated_at) %}
            @{{ivar.name}} = nil
          {% elsif (primary = @type.constant(:PRIMARY_KEY)) && ivar.name == primary.id %}
            @{{ivar.name}} = nil
          {% elsif ivar.type.nilable? %}
            @{{ivar.name}} = {{attributes}}[{{ivar.name.stringify}}]?
          {% else %}
            @{{ivar.name}} = {{attributes}}[{{ivar.name.stringify}}]
          {% end %}
        {% end %}
      {% end %}
    end

    macro __caramel_valid_body
      @__caramel_errors.clear
      {% for ivar in @type.instance_vars %}
        {% validation_constant = "VALIDATE_#{ivar.name.id.upcase}_PRESENCE".id %}
        {% if !ivar.name.stringify.starts_with?("__") && @type.constant(validation_constant) %}
          if @{{ivar.name}}.nil? || @{{ivar.name}}.to_s.strip.empty?
            @__caramel_errors[{{ivar.name.stringify}}] = ["must be present"]
          end
        {% end %}
      {% end %}
      @__caramel_errors.empty?
    end

    macro __caramel_load_system_body(values)
      {% timestamps_enabled = @type.constant(:TIMESTAMPS_ENABLED) == true %}
      {% primary = @type.constant(:PRIMARY_KEY) %}
      {% for ivar in @type.instance_vars %}
        {% if @type.constant("FIELD_#{ivar.name.id.upcase}".id) %}
          {% if primary && ivar.name == primary.id %}
            @{{ivar.name}} = {{values}}[{{ivar.name.stringify}}]
          {% elsif timestamps_enabled && (ivar.name == :created_at || ivar.name == :updated_at) %}
            @{{ivar.name}} = {{values}}[{{ivar.name.stringify}}]
          {% end %}
        {% end %}
      {% end %}
    end

    macro __caramel_select_list_body
      {% fields = [] of TypeNode %}
      {% for ivar in @type.instance_vars %}
        {% if @type.constant("FIELD_#{ivar.name.id.upcase}".id) %}
          {% fields << ivar %}
        {% end %}
      {% end %}
      String.build do |io|
        {% for ivar, index in fields %}
          io << ", " unless {{index}} == 0
          io << __caramel_quote_identifier({{ivar.name.stringify}})
        {% end %}
      end
    end

    macro __caramel_from_row_body(result)
      {% timestamps_enabled = @type.constant(:TIMESTAMPS_ENABLED) == true %}
      {% primary = @type.constant(:PRIMARY_KEY) %}
      {% fields = [] of TypeNode %}
      {% user_fields = [] of TypeNode %}
      {% for ivar in @type.instance_vars %}
        {% if @type.constant("FIELD_#{ivar.name.id.upcase}".id) %}
          {% fields << ivar %}
          {% if (primary && ivar.name == primary.id) || (timestamps_enabled && (ivar.name == :created_at || ivar.name == :updated_at)) %}
          {% else %}
            {% user_fields << ivar %}
          {% end %}
        {% end %}
      {% end %}
      {% for ivar in fields %}
        value_{{ivar.name}} = {{result}}.read({{ivar.type}})
      {% end %}
      object = new(
        {% for ivar, index in user_fields %}
          {{ivar.name}}: value_{{ivar.name}}{% unless index == user_fields.size - 1 %},{% end %}
        {% end %}
      )
      object.__caramel_load_system_values(
        {% for ivar, index in fields %}
          {% if (primary = @type.constant(:PRIMARY_KEY)) && ivar.name == primary.id %}
            {{ivar.name}}: value_{{ivar.name}}{% unless index == fields.size - 1 %},{% end %}
          {% elsif @type.constant(:TIMESTAMPS_ENABLED) == true && (ivar.name == :created_at || ivar.name == :updated_at) %}
            {{ivar.name}}: value_{{ivar.name}}{% unless index == fields.size - 1 %},{% end %}
          {% end %}
        {% end %}
      )
      object.__caramel_mark_persisted
      object
    end

    macro __caramel_save_body
      {% primary = @type.constant(:PRIMARY_KEY) %}
      {% raise "Caramel::Model requires a nullable primary field" unless primary %}
      {% timestamps_enabled = @type.constant(:TIMESTAMPS_ENABLED) == true %}
      {% fields = [] of TypeNode %}
      {% user_fields = [] of TypeNode %}
      {% for ivar in @type.instance_vars %}
        {% if @type.constant("FIELD_#{ivar.name.id.upcase}".id) %}
          {% fields << ivar %}
          {% if ivar.name == primary.id || (timestamps_enabled && (ivar.name == :created_at || ivar.name == :updated_at)) %}
          {% else %}
            {% user_fields << ivar %}
          {% end %}
        {% end %}
      {% end %}
      return false unless valid?
      if __caramel_deleted?
        @__caramel_errors["_base"] = ["Record has been deleted"]
        return false
      end

      if __caramel_persisted?
        {% for ivar in @type.instance_vars %}
          {% if ivar.name == primary.id %}
            return false if @{{ivar.name}}.nil?
          {% end %}
        {% end %}
        {% if user_fields.empty? && !timestamps_enabled %}
          # There is nothing to write, but a missing row still has the same
          # explicit failure as an ordinary update. Do not fire UPDATE triggers.
          exists = self.class.database.query_one?(
            "SELECT 1 FROM " + self.class.__caramel_table_sql + " WHERE " + self.class.__caramel_quote_identifier({{primary.id.stringify}}) + " = $1",
            @{{primary.id}}.not_nil!, as: Int32
          )
          unless exists
            @__caramel_errors["_base"] = ["Record no longer exists"]
            return false
          end
          return true
        {% else %}
        args = [] of DB::Any
        sql = "UPDATE " + self.class.__caramel_table_sql + " SET "
        {% for ivar, index in user_fields %}
          sql += ", " unless {{index}} == 0
          sql += self.class.__caramel_quote_identifier({{ivar.name.stringify}}) + " = ${{index + 1}}"
          args << @{{ivar.name}}
        {% end %}
        {% if timestamps_enabled %}
          sql += ", " unless {{user_fields.size}} == 0
          sql += self.class.__caramel_quote_identifier("updated_at") + " = CURRENT_TIMESTAMP"
        {% end %}
        sql += " WHERE " + self.class.__caramel_quote_identifier({{primary.id.stringify}}) + " = ${{user_fields.size + 1}}"
        {% for ivar in @type.instance_vars %}
          {% if ivar.name == primary.id %}
            args << @{{ivar.name}}.not_nil!
          {% end %}
        {% end %}
        {% if timestamps_enabled %}
          sql += " RETURNING " + self.class.__caramel_quote_identifier("updated_at")
          updated_at = self.class.database.query_one?(sql, args: args) { |result| result.read(Time) }
          unless updated_at
            @__caramel_errors["_base"] = ["Record no longer exists"]
            return false
          end
          @updated_at = updated_at
        {% else %}
          unless self.class.database.exec(sql, args: args).rows_affected == 1
            @__caramel_errors["_base"] = ["Record no longer exists"]
            return false
          end
        {% end %}
        true
        {% end %}
      else
        args = [] of DB::Any
        {% if user_fields.empty? %}
          sql = "INSERT INTO " + self.class.__caramel_table_sql + " DEFAULT VALUES"
        {% else %}
          sql = "INSERT INTO " + self.class.__caramel_table_sql + " ("
          {% for ivar, index in user_fields %}
            sql += ", " unless {{index}} == 0
            sql += self.class.__caramel_quote_identifier({{ivar.name.stringify}})
            args << @{{ivar.name}}
          {% end %}
          sql += ") VALUES ("
          {% for ivar, index in user_fields %}
            sql += ", " unless {{index}} == 0
            sql += "${{index + 1}}"
          {% end %}
          sql += ")"
        {% end %}
        sql += " RETURNING "
        {% returning_fields = fields.select { |ivar| ivar.name == primary.id || (timestamps_enabled && (ivar.name == :created_at || ivar.name == :updated_at)) } %}
        {% for ivar, index in returning_fields %}
          sql += ", " unless {{index}} == 0
          sql += self.class.__caramel_quote_identifier({{ivar.name.stringify}})
        {% end %}
        self.class.database.query_one(sql, args: args) do |result|
          {% for ivar in fields %}
            {% if ivar.name == primary.id || (@type.constant(:TIMESTAMPS_ENABLED) == true && (ivar.name == :created_at || ivar.name == :updated_at)) %}
              @{{ivar.name}} = result.read({{ivar.type}})
            {% end %}
          {% end %}
        end
        __caramel_mark_persisted
        true
      end
    end

    macro __caramel_delete_body
      {% primary = @type.constant(:PRIMARY_KEY) %}
      {% raise "Caramel::Model requires a nullable primary field" unless primary %}
      return false unless __caramel_persisted?
      return false if __caramel_deleted?
      args = [] of DB::Any
      {% for ivar in @type.instance_vars %}
        {% if ivar.name == primary.id %}
          return false if @{{ivar.name}}.nil?
          args << @{{ivar.name}}.not_nil!
        {% end %}
      {% end %}
      deleted = self.class.database.exec(
        "DELETE FROM " + self.class.__caramel_table_sql + " WHERE " + self.class.__caramel_quote_identifier({{primary.id.stringify}}) + " = $1",
        args: args
      ).rows_affected == 1
      __caramel_mark_deleted if deleted
      deleted
    end

    macro __caramel_find_body(id)
      {% primary = @type.constant(:PRIMARY_KEY) %}
      {% raise "Caramel::Model requires a nullable primary field" unless primary %}
      sql = "SELECT " + __caramel_select_list + " FROM " + __caramel_table_sql + " WHERE " + __caramel_quote_identifier({{primary.id.stringify}}) + " = $1 LIMIT 1"
      database.query_one?(sql, {{id}}) { |result| __caramel_from_row(result) }
    end

    macro where(**conditions)
      conditions = [] of Caramel::Model::Condition
      {% for name, value in conditions %}
        {% field_constant = "FIELD_#{name.id.upcase}".id %}
        {% unless @type.constant(field_constant) %}
          {% raise "unknown Caramel::Model query field: #{name.id}" %}
        {% end %}
        conditions << {{@type}}.__caramel_condition_{{name.id}}({{value}})
      {% end %}
      Caramel::Model::Query({{@type}}).new(conditions)
    end

    macro order(**orders)
      query = Caramel::Model::Query({{@type}}).new
      {% for name, direction in orders %}
        query = query.order({{name}}: {{direction}})
      {% end %}
      query
    end

    macro inherited
      {% unless @type.abstract? %}
        def initialize(**attributes : **U) forall U
          {% verbatim do %}
            {% for key in U.type_vars[0].keys %}
              {% field_constant = "FIELD_#{key.id.upcase}".id %}
              {% if !@type.constant(field_constant) || key == @type.constant(:PRIMARY_KEY) || (@type.constant(:TIMESTAMPS_ENABLED) == true && (key == :created_at || key == :updated_at)) %}
                {% raise "unknown or system-managed Caramel::Model constructor field: #{key}" %}
              {% end %}
            {% end %}
          {% end %}
          __caramel_initialize_body(attributes)
        end

        def valid? : Bool
          __caramel_valid_body
        end

        def __caramel_load_system_values(**values) : Nil
          __caramel_load_system_body(values)
        end

        def save : Bool
          __caramel_save_body
        end

        def delete : Bool
          __caramel_delete_body
        end

        def destroy : Bool
          delete
        end

        def self.__caramel_table_sql : String
          __caramel_table_sql_body
        end

        def self.__caramel_select_list : String
          __caramel_select_list_body
        end

        def self.__caramel_from_row(result : DB::ResultSet) : self
          __caramel_from_row_body(result)
        end

        def self.find(id : Int64) : self?
          __caramel_find_body(id)
        end
      {% end %}
    end

    macro __caramel_table_sql_body
      {% table = @type.constant(:TABLE_NAME) %}
      {% raise "concrete Caramel::Model must declare table :name" unless table %}
      __caramel_quote_identifier({{table}})
    end
  end

  # A chainable, read-only query builder with compile-time field validation.
  class Model::Query(T)
    @orders : Array(Tuple(String, Symbol))
    @limit : Int32?

    def initialize(@conditions : Array(Model::Condition) = [] of Model::Condition)
      @orders = [] of Tuple(String, Symbol)
      @limit = nil
    end

    def order(**orders : **U) : self forall U
      {% for key in U.type_vars[0].keys %}
        {% field_constant = "FIELD_#{key.id.upcase}".id %}
        {% unless T.constant(field_constant) %}
          {% raise "unknown Caramel::Model order field: #{key.id}" %}
        {% end %}
        direction = orders[:{{key.id}}]
        unless direction == :asc || direction == :desc
          raise ArgumentError.new("order direction must be :asc or :desc")
        end
        @orders << {T.__caramel_quote_identifier({{key.stringify}}), direction}
      {% end %}
      self
    end

    def where(**conditions : **U) : self forall U
      {% for key in U.type_vars[0].keys %}
        {% field_constant = "FIELD_#{key.id.upcase}".id %}
        {% unless T.constant(field_constant) %}
          {% raise "unknown Caramel::Model query field: #{key.id}" %}
        {% end %}
        @conditions << T.__caramel_condition_{{key.id}}(conditions[:{{key.id}}])
      {% end %}
      self
    end

    def limit(value : Int32) : self
      raise ArgumentError.new("limit must be positive") unless value > 0
      @limit = value
      self
    end

    def to_a : Array(T)
      sql = "SELECT " + T.__caramel_select_list + " FROM " + T.__caramel_table_sql
      args = [] of DB::Any
      unless @conditions.empty?
        bind_index = 0
        predicates = @conditions.map do |condition|
          condition.sql.gsub("?") do
            bind_index += 1
            "$#{bind_index}"
          end
        end
        sql += " WHERE " + predicates.join(" AND ")
        @conditions.each { |condition| args.concat(condition.values) }
      end
      unless @orders.empty?
        sql += " ORDER BY " + @orders.map { |column, direction| "#{column} #{direction == :asc ? "ASC" : "DESC"}" }.join(", ")
      end
      sql += " LIMIT #{@limit.not_nil!}" if @limit
      T.database.query_all(sql, args: args) { |result| T.__caramel_from_row(result) }
    end
  end
end
