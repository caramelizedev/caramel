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

  # ` AND "<tenant column>" = $n`, with the tenant appended to *args*, when
  # `T` is tenanted and scoped; "" otherwise.
  def self.tenant_filter(schema : T.class, args : Array(Value)) : String forall T
    {% if T.has_constant?(:SUGAR_TENANT) %}
      tenant = T.__sugar_tenant_scope || return ""
      args << tenant
      %( AND "#{T.__sugar_tenant_column}" = $#{args.size})
    {% else %}
      ""
    {% end %}
  end

  record Clauses,
    conditions : Array(Condition) = [] of Condition,
    orders : Array(String) = [] of String,
    limit : Int32? = nil,
    offset : Int32? = nil,
    lock : Bool = false

  # An immutable query over schema `T`; `P` is the NamedTuple of preload
  # loaders. Every clause returns a new query. Each schema generates
  # `T::QueryOf(P)` with its typed `where` and `preload` overloads.
  abstract struct Query(T, P)
    # Fully qualified: the generated `T::QueryOf` expands these defaults in its
    # own scope.
    def initialize(@clauses : ::SugarORM::Clauses = ::SugarORM::Clauses.new,
                   @preloads : P = NamedTuple.new)
    end

    # A raw predicate with `?` binds: `where("seats > ?", 3)`.
    def where(fragment : String, *args) : self
      placeholders = fragment.count('?')
      unless placeholders == args.size
        message = "where(#{fragment.inspect}) has #{placeholders} '?' placeholders " \
                  "but #{args.size} values"
        raise ArgumentError.new(message)
      end
      values = [] of Value
      args.each { |arg| values << arg }
      __sugar_where([::SugarORM::Condition.new("(#{fragment})", values)])
    end

    # `field` is checked at compile time through the generated `T::Field` enum.
    # `direction` stays a Symbol so an unknown field is reported on the field:
    # Crystal misattributes the failure when two symbol arguments autocast.
    def order_by(field : T::Field, direction : Symbol = :asc) : self
      sql = direction_sql(direction)
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

    # Locks the rows this query returns (`FOR UPDATE`) until the transaction ends. Order the
    # query (`order_by(:id)`) so competing transactions lock several rows in one order; a
    # lock does not replace a permission check. Preloaded associations are not locked.
    def lock : self
      self.class.new(@clauses.copy_with(lock: true), @preloads)
    end

    protected def __sugar_where(conditions : Array(::SugarORM::Condition)) : self
      clauses = @clauses.copy_with(conditions: @clauses.conditions + conditions)
      self.class.new(clauses, @preloads)
    end

    # The SELECT this query runs (before preloads), for inspection.
    def to_sql : String
      String.build do |io|
        io << "SELECT " << T.__sugar_select_list << " FROM " << T.__sugar_quoted_table
        write_filters(io, order: true)
        io << " FOR UPDATE" if @clauses.lock
      end
    end

    # The bind values for `to_sql`, in `$n` order.
    def binds : Array(::SugarORM::Value)
      conditions.flat_map(&.values)
    end

    # All matching records: `Array(T)`, or `Array(Loaded(T, L))` once preloaded.
    # Each preloaded association costs exactly one extra query.
    def to_a
      refuse_lock_outside_transaction
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
      condition = ::SugarORM::Condition.column(T.__sugar_primary_key, id)
      __sugar_where([condition]).limit(1).to_a.first?
    end

    def find!(id : Int64)
      find(id) || raise ::SugarORM::NotFound.new(
        "#{T} with #{T.__sugar_primary_key} = #{id} was not found"
      )
    end

    def count : Int64
      refuse_lock("count")
      table = T.__sugar_quoted_table
      sql = if @clauses.limit || @clauses.offset
              "SELECT count(*) FROM (SELECT 1 FROM #{table}#{filters}) AS sugar_count"
            else
              "SELECT count(*) FROM #{table}#{filters(order: false)}"
            end
      ::SugarORM::Repo.query_one?(sql, binds, &.read(Int64)) || 0_i64
    end

    def exists? : Bool
      refuse_lock("exists?")
      sql = "SELECT EXISTS (SELECT 1 FROM #{T.__sugar_quoted_table}#{filters})"
      ::SugarORM::Repo.query_one?(sql, binds, &.read(Bool)) || false
    end

    # Deletes every matching row and returns how many were deleted.
    def delete_all : Int64
      refuse_lock("delete_all")
      table = T.__sugar_quoted_table
      sql = if @clauses.limit || @clauses.offset
              primary_key = %("#{T.__sugar_primary_key}")
              matching = "SELECT #{primary_key} FROM #{table}#{filters}"
              "DELETE FROM #{table} WHERE #{primary_key} IN (#{matching})"
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

    def self.lock
      new.lock
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
      order = %("#{T.__sugar_primary_key}" ASC)
      self.class.new(@clauses.copy_with(orders: [order]), @preloads)
    end

    private def direction_sql(direction : Symbol) : String
      case direction
      when :asc  then "ASC"
      when :desc then "DESC"
      else
        raise ArgumentError.new(
          "order_by direction must be :asc or :desc, not #{direction.inspect}"
        )
      end
    end

    private def refuse_lock(terminal : String) : Nil
      return unless @clauses.lock
      raise ArgumentError.new("#{terminal} does not lock rows; remove .lock from this query")
    end

    private def refuse_lock_outside_transaction : Nil
      return unless @clauses.lock
      return if ::SugarORM::Repo.in_transaction?
      raise ::SugarORM::Error.new(
        "#{T} query locks its rows (FOR UPDATE), but no transaction is open, " \
        "so the lock would end with the statement.\n" \
        "Remediation: run it inside SugarORM::Repo.transaction { … }."
      )
    end

    private def filters(order : Bool = true) : String
      String.build { |io| write_filters(io, order) }
    end

    # The query's conditions, led by its tenant's when `T` is tenanted. The
    # scope applies when the query runs, so no chained call can remove it.
    private def conditions : Array(::SugarORM::Condition)
      {% if T.has_constant?(:SUGAR_TENANT) %}
        if tenant = T.__sugar_tenant_scope
          scope = ::SugarORM::Condition.column(T.__sugar_tenant_column, tenant)
          return [scope] + @clauses.conditions
        end
      {% end %}
      @clauses.conditions
    end

    private def write_filters(io : IO, order : Bool) : Nil
      predicates = conditions
      unless predicates.empty?
        index = 0
        io << " WHERE "
        predicates.join(io, " AND ") do |condition, inner|
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
