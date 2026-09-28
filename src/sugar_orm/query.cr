module SugarORM
  # One WHERE predicate; `?` marks each bind and becomes `$n` when rendered.
  record Condition, sql : String, values : Array(Value) do
    def self.column(column : String, value : Nil) : self
      new(%("#{column}" IS NULL), [] of Value)
    end

    def self.column(column : String, value : Array) : self
      new(%("#{column}" = ANY(?)), [value] of Value)
    end

    def self.column(column : String, value : Range) : self
      quoted = %("#{column}")
      first = value.begin
      last = value.end
      if first.nil? && last.nil?
        new("TRUE", [] of Value)
      elsif first.nil?
        new("#{quoted} #{value.excludes_end? ? "<" : "<="} ?", [last] of Value)
      elsif last.nil?
        new("#{quoted} >= ?", [first] of Value)
      elsif value.excludes_end?
        new("#{quoted} >= ? AND #{quoted} < ?", [first, last] of Value)
      else
        new("#{quoted} BETWEEN ? AND ?", [first, last] of Value)
      end
    end

    def self.column(column : String, value) : self
      new(%("#{column}" = ?), [value] of Value)
    end
  end

  record Clauses,
    conditions : Array(Condition) = [] of Condition,
    orders : Array(String) = [] of String,
    limit : Int32? = nil,
    offset : Int32? = nil

  # An immutable query over schema `T`; `P` is the NamedTuple of preload
  # loaders. Every clause returns a new query. Each schema generates
  # `T::QueryOf(P)` with its typed `where` and `preload` overloads.
  abstract struct Query(T, P)
    # Fully qualified: the generated `T::QueryOf` expands these defaults in its own scope.
    def initialize(@clauses : ::SugarORM::Clauses = ::SugarORM::Clauses.new, @preloads : P = NamedTuple.new)
    end

    # A raw predicate with `?` binds: `where("seats > ?", 3)`.
    def where(fragment : String, *args) : self
      placeholders = fragment.count('?')
      unless placeholders == args.size
        raise ArgumentError.new("where(#{fragment.inspect}) has #{placeholders} '?' placeholders but #{args.size} values")
      end
      values = [] of Value
      args.each { |arg| values << arg }
      __sugar_where([::SugarORM::Condition.new("(#{fragment})", values)])
    end

    # `field` is checked at compile time through the generated `T::Field` enum.
    # `direction` stays a Symbol so an unknown field is reported on the field:
    # Crystal misattributes the failure when two symbol arguments autocast.
    def order_by(field : T::Field, direction : Symbol = :asc) : self
      sql = case direction
            when :asc  then "ASC"
            when :desc then "DESC"
            else            raise ArgumentError.new("order_by direction must be :asc or :desc, not #{direction.inspect}")
            end
      order = %("#{T.__sugar_column(field)}" #{sql})
      self.class.new(@clauses.copy_with(orders: @clauses.orders + [order]), @preloads)
    end

    def limit(count : Int32) : self
      raise ArgumentError.new("limit must not be negative") if count < 0
      self.class.new(@clauses.copy_with(limit: count), @preloads)
    end

    def offset(count : Int32) : self
      raise ArgumentError.new("offset must not be negative") if count < 0
      self.class.new(@clauses.copy_with(offset: count), @preloads)
    end

    protected def __sugar_where(conditions : Array(::SugarORM::Condition)) : self
      self.class.new(@clauses.copy_with(conditions: @clauses.conditions + conditions), @preloads)
    end

    # The SELECT this query runs (before preloads), for inspection.
    def to_sql : String
      String.build do |io|
        io << "SELECT " << T.__sugar_select_list << " FROM " << T.__sugar_quoted_table
        write_filters(io, order: true)
      end
    end

    # The bind values for `to_sql`, in `$n` order.
    def binds : Array(::SugarORM::Value)
      @clauses.conditions.flat_map(&.values)
    end

    # All matching records: `Array(T)`, or `Array(Loaded(T, L))` once preloaded.
    # Each preloaded association costs exactly one extra query.
    def to_a
      records = ::SugarORM::Repo.query_all(to_sql, binds) { |rows| T.from_row(rows) }
      {% if P.keys.empty? %}
        records
      {% else %}
        {% for key in P.keys %}
          %loaded{key} = @preloads[{{ key.symbolize }}].load(records)
        {% end %}
        records.map_with_index do |record, index|
          ::SugarORM::Loaded.new(record, {
            {% for key in P.keys %}
              {{ key }}: %loaded{key}[index],
            {% end %}
          })
        end
      {% end %}
    end

    def each(&) : Nil
      to_a.each { |record| yield record }
    end

    # The first record by the query's order (primary key when unordered), or nil.
    def first
      query = @clauses.orders.empty? ? order_by_primary_key : self
      query.limit(1).to_a.first?
    end

    def first!
      first || raise ::SugarORM::NotFound.new("No #{T} matched: #{to_sql}")
    end

    def find(id : Int64)
      __sugar_where([::SugarORM::Condition.column(T.__sugar_primary_key, id)]).limit(1).to_a.first?
    end

    def find!(id : Int64)
      find(id) || raise ::SugarORM::NotFound.new("#{T} with #{T.__sugar_primary_key} = #{id} was not found")
    end

    def count : Int64
      sql = if @clauses.limit || @clauses.offset
              "SELECT count(*) FROM (SELECT 1 FROM #{T.__sugar_quoted_table}#{filters}) AS sugar_count"
            else
              "SELECT count(*) FROM #{T.__sugar_quoted_table}#{filters(order: false)}"
            end
      ::SugarORM::Repo.query_one?(sql, binds, &.read(Int64)) || 0_i64
    end

    def exists? : Bool
      sql = "SELECT EXISTS (SELECT 1 FROM #{T.__sugar_quoted_table}#{filters})"
      ::SugarORM::Repo.query_one?(sql, binds, &.read(Bool)) || false
    end

    # Deletes every matching row and returns how many were deleted.
    def delete_all : Int64
      table = T.__sugar_quoted_table
      sql = if @clauses.limit || @clauses.offset
              primary_key = %("#{T.__sugar_primary_key}")
              "DELETE FROM #{table} WHERE #{primary_key} IN (SELECT #{primary_key} FROM #{table}#{filters})"
            else
              "DELETE FROM #{table}#{filters(order: false)}"
            end
      ::SugarORM::Repo.exec(sql, binds).rows_affected
    end

    def to_a(db : ::SugarORM::Handle)
      ::SugarORM::Repo.using(db) { to_a }
    end

    def each(db : ::SugarORM::Handle, &) : Nil
      ::SugarORM::Repo.using(db) { each { |record| yield record } }
    end

    {% for name in %w[first first! count exists? delete_all] %}
      def {{ name.id }}(db : ::SugarORM::Handle)
        ::SugarORM::Repo.using(db) { {{ name.id }} }
      end
    {% end %}

    def find(db : ::SugarORM::Handle, id : Int64)
      ::SugarORM::Repo.using(db) { find(id) }
    end

    def find!(db : ::SugarORM::Handle, id : Int64)
      ::SugarORM::Repo.using(db) { find!(id) }
    end

    # `Team::Query.where(...)` and friends start from an empty query.
    def self.where(fragment : String, *args)
      new.where(fragment, *args)
    end

    def self.order_by(field : T::Field, direction : Symbol = :asc)
      new.order_by(field, direction)
    end

    def self.limit(count : Int32)
      new.limit(count)
    end

    def self.offset(count : Int32)
      new.offset(count)
    end

    {% for name in %w[to_a first first! count exists? delete_all] %}
      def self.{{ name.id }}
        new.{{ name.id }}
      end

      def self.{{ name.id }}(db : ::SugarORM::Handle)
        new.{{ name.id }}(db)
      end
    {% end %}

    def self.each(&) : Nil
      new.each { |record| yield record }
    end

    def self.each(db : ::SugarORM::Handle, &) : Nil
      new.each(db) { |record| yield record }
    end

    def self.find(id : Int64)
      new.find(id)
    end

    def self.find(db : ::SugarORM::Handle, id : Int64)
      new.find(db, id)
    end

    def self.find!(id : Int64)
      new.find!(id)
    end

    def self.find!(db : ::SugarORM::Handle, id : Int64)
      new.find!(db, id)
    end

    private def order_by_primary_key : self
      self.class.new(@clauses.copy_with(orders: [%("#{T.__sugar_primary_key}" ASC)]), @preloads)
    end

    private def filters(order : Bool = true) : String
      String.build { |io| write_filters(io, order) }
    end

    private def write_filters(io : IO, order : Bool) : Nil
      unless @clauses.conditions.empty?
        index = 0
        io << " WHERE "
        @clauses.conditions.join(io, " AND ") do |condition, inner|
          inner << condition.sql.gsub("?") { index += 1; "$#{index}" }
        end
      end
      io << " ORDER BY " << @clauses.orders.join(", ") if order && !@clauses.orders.empty?
      if limit = @clauses.limit
        io << " LIMIT " << limit
      end
      if offset = @clauses.offset
        io << " OFFSET " << offset
      end
    end
  end
end
