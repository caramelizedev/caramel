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

  # What a keyword `where` returns for a value that may be nil. Each schema
  # generates `T::<Column>MayBeNil(Remediation)`, which has no query methods.
  abstract struct MayBeNil
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

  # One INNER JOIN a query holds: a derived table over a parent query, whose columns carry
  # the prefix `sugar_<name>__`. Its `?` binds are numbered with the query's.
  record Join, name : String, sql : String, values : Array(Value)

  record Clauses,
    conditions : Array(Condition) = [] of Condition,
    orders : Array(String) = [] of String,
    limit : Int32? = nil,
    offset : Int32? = nil,
    lock : Bool = false,
    joins : Array(Join) = [] of Join

  # Numbers the `?` of each fragment `$1`, `$2`, … in the order the fragments are written.
  class PlaceholderCounter
    def initialize
      @count = 0
    end

    def number(sql : String) : String
      sql.gsub("?") { "$#{@count += 1}" }
    end
  end

  # One page of a keyset read: `after` is the cursor for the next page, nil on the last.
  struct Page(R)
    getter records : Array(R)
    getter after : Int64?

    def initialize(@records : Array(R), @after : Int64?)
    end
  end

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

    # A predicate built as a `Condition`, such as a SweetTalk specification's. Its `?`
    # binds take its values in order, and it is parenthesized, as a fragment is, so an
    # `OR` inside it cannot reach the conditions beside it. It is not an overload of
    # `where`, which would turn "no parameter named" into "no overload matches".
    def where_condition(condition : ::SugarORM::Condition) : self
      __sugar_where([::SugarORM::Condition.new("(#{condition.sql})", condition.values)])
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
        io << "SELECT " << T.__sugar_select_list << " FROM "
        write_source(io, order: true)
        io << " FOR UPDATE" if @clauses.lock
      end
    end

    # The bind values for `to_sql`, in `$n` order: the joins' first, then the conditions'.
    def binds : Array(::SugarORM::Value)
      @clauses.joins.flat_map(&.values) + conditions.flat_map(&.values)
    end

    # All matching records: `Array(T)`, or `Array(Loaded(T, L))` once preloaded.
    # Each preloaded association costs exactly one extra query.
    def to_a
      refuse_lock_with_joins
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
      sql = if @clauses.limit || @clauses.offset
              "SELECT count(*) FROM (SELECT 1 FROM #{source}) AS sugar_count"
            else
              "SELECT count(*) FROM #{source(order: false)}"
            end
      ::SugarORM::Repo.query_one?(sql, binds, &.read(Int64)) || 0_i64
    end

    def exists? : Bool
      refuse_lock("exists?")
      sql = "SELECT EXISTS (SELECT 1 FROM #{source})"
      ::SugarORM::Repo.query_one?(sql, binds, &.read(Bool)) || false
    end

    # The sum of *field* over the matching rows as PostgreSQL's exact text: "0" when no
    # row matches or every value is NULL. Text keeps an integer, bigint, numeric or double
    # precision sum exact without a Crystal type per column; the caller builds its type.
    def sum_text(field : T::Field) : String
      refuse_lock("sum_text")
      column = %("#{T.__sugar_column(field)}")
      sql = if @clauses.limit || @clauses.offset
              inner = "SELECT #{column} FROM #{source}"
              "SELECT coalesce(sum(#{column}), 0)::text FROM (#{inner}) AS sugar_sum"
            else
              "SELECT coalesce(sum(#{column}), 0)::text FROM #{source(order: false)}"
            end
      ::SugarORM::Repo.query_one?(sql, binds, &.read(String)) || "0"
    end

    {% for name in %w[min max avg] %}
      # The {{ name.id }} of *field* over the matching rows as PostgreSQL's exact text, or nil
      # when no row matches or every value is NULL. Like `sum_text`, the caller builds its type.
      def {{ name.id }}_text(field : T::Field) : String?
        refuse_lock({{ "#{name.id}_text" }})
        column = %("#{T.__sugar_column(field)}")
        sql = if @clauses.limit || @clauses.offset
                inner = "SELECT #{column} FROM #{source}"
                "SELECT {{ name.id }}(#{column})::text FROM (#{inner}) AS sugar_{{ name.id }}"
              else
                "SELECT {{ name.id }}(#{column})::text FROM #{source(order: false)}"
              end
        ::SugarORM::Repo.query_one?(sql, binds, &.read(String?))
      end
    {% end %}

    # Each value of *by* among the matching rows, as text (nil for NULL), with the sum of
    # *of* over its rows as exact text, ordered by *by* (NULL last).
    def group_sum_text(by : T::Field, of : T::Field) : Array({String?, String})
      refuse_lock("group_sum_text")
      unless @clauses.orders.empty?
        raise ArgumentError.new(
          "group_sum_text orders by its key; remove order_by from this query"
        )
      end
      if @clauses.limit || @clauses.offset
        raise ArgumentError.new(
          "group_sum_text groups every matching row; remove limit and offset from this query"
        )
      end
      key = %("#{T.__sugar_column(by)}")
      column = %("#{T.__sugar_column(of)}")
      sql = "SELECT #{key}::text, coalesce(sum(#{column}), 0)::text " \
            "FROM #{source(order: false)} GROUP BY #{key} ORDER BY #{key}"
      ::SugarORM::Repo.query_all(sql, binds) { |rows| {rows.read(String?), rows.read(String)} }
    end

    # Each value of *by* among the matching rows, as text (nil for NULL), with how many rows
    # hold it, ordered by *by* (NULL last).
    def group_count(by : T::Field) : Array({String?, Int64})
      refuse_lock("group_count")
      unless @clauses.orders.empty?
        raise ArgumentError.new(
          "group_count orders by its key; remove order_by from this query"
        )
      end
      if @clauses.limit || @clauses.offset
        raise ArgumentError.new(
          "group_count groups every matching row; remove limit and offset from this query"
        )
      end
      key = %("#{T.__sugar_column(by)}")
      sql = "SELECT #{key}::text, count(*) FROM #{source(order: false)} " \
            "GROUP BY #{key} ORDER BY #{key}"
      ::SugarORM::Repo.query_all(sql, binds) { |rows| {rows.read(String?), rows.read(Int64)} }
    end

    # Reads every matching row in batches of *size*, in primary-key order, one statement per
    # batch, and yields each batch as `to_a` returns its rows. A short batch is the last.
    # The query sets its own order and limit, so it takes neither.
    def each_batch(size : Int32 = 1000, &)
      refuse_keyset("each_batch", size)
      raise ArgumentError.new(
        "each_batch reads in several statements; remove .lock from this query"
      ) if @clauses.lock
      cursor = nil.as(Int64?)
      loop do
        records = keyset(cursor, :asc, size).to_a
        break if records.empty?
        yield records
        break if records.size < size
        cursor = records.last.__sugar_primary_value
      end
    end

    # One page of *size* rows in primary-key order, after the row *after* names (the cursor
    # a page returned), ascending or `direction: :desc`. `after` of the result is the cursor
    # of the next page, nil on the last.
    def page(size : Int32, after : Int64? = nil, direction : Symbol = :asc)
      refuse_keyset("page", size)
      unless direction.in?(:asc, :desc)
        raise ArgumentError.new("page direction must be :asc or :desc, not #{direction.inspect}")
      end
      records = keyset(after, direction, size + 1).to_a
      more = records.size > size
      records = records.first(size)
      ::SugarORM::Page.new(records, more ? records.last.__sugar_primary_value : nil)
    end

    # Narrows to the rows whose *field* holds the key of a row *parent* matches:
    # "field" IN (SELECT "<pk>" FROM <parent table> WHERE …), with the parent's conditions,
    # tenant included, read when this is called.
    def where_in(field : T::Field, parent : ::SugarORM::Query(U, Q)) : self forall U, Q
      where_condition(parent.__sugar_in_condition(T.__sugar_column(field)))
    end

    # The condition `where_in` adds to a query over another schema; public for that call only.
    def __sugar_in_condition(column : String) : ::SugarORM::Condition
      refuse_lock("where_in")
      unless @clauses.joins.empty?
        raise ArgumentError.new("where_in takes a parent query without joins")
      end
      predicates = conditions
      sql = String.build do |io|
        io << "\"#{column}\" IN (SELECT \"#{T.__sugar_primary_key}\" FROM "
        write_source(io, order: true, numbered: false)
        io << ")"
      end
      ::SugarORM::Condition.new(sql, predicates.flat_map(&.values))
    end

    # The join `joins` adds to a query over another schema; public for that call only. The
    # parent's rows become a derived table whose columns are prefixed `sugar_<name>__`, so
    # the base query's unqualified columns stay unambiguous.
    def __sugar_join_condition(name : String, owner : String, column : String) : ::SugarORM::Join
      refuse_lock("joins")
      unless @clauses.joins.empty?
        raise ArgumentError.new("joins takes a parent query without joins")
      end
      table = "sugar_#{name}"
      selected = T.__sugar_column_names.map do |each|
        %("#{each}" AS "#{table}__#{each}")
      end
      key = %("#{table}"."#{table}__#{T.__sugar_primary_key}")
      sql = String.build do |io|
        io << "INNER JOIN (SELECT " << selected.join(", ") << " FROM "
        write_source(io, order: true, numbered: false)
        io << ") AS \"" << table << "\" ON " << key << " = " << owner << %(."#{column}")
      end
      ::SugarORM::Join.new(name, sql, conditions.flat_map(&.values))
    end

    # Adds the INNER JOIN of the association *name*, keeping the rows whose *column* holds
    # the key of a row *parent* matches. Each association is joined once.
    protected def __sugar_join(name : String,
                               column : String,
                               parent : ::SugarORM::Query(U, Q)) : self forall U, Q
      if @clauses.joins.any? { |join| join.name == name }
        raise ArgumentError.new("joins(:#{name}) is given twice; pass one parent query")
      end
      join = parent.__sugar_join_condition(name, T.__sugar_quoted_table, column)
      self.class.new(@clauses.copy_with(joins: @clauses.joins + [join]), @preloads)
    end

    # Orders by *column* of the association *name*, which `joins` must have joined first.
    protected def __sugar_order_by_joined(name : String, column : String, direction : Symbol) : self
      unless @clauses.joins.any? { |join| join.name == name }
        raise ArgumentError.new("order_by_joined(:#{name}, …) needs joins(:#{name}) first")
      end
      order = %("sugar_#{name}__#{column}" #{direction_sql(direction)})
      self.class.new(@clauses.copy_with(orders: @clauses.orders + [order]), @preloads)
    end

    # Deletes every matching row and returns how many were deleted.
    def delete_all : Int64
      refuse_lock("delete_all")
      unless @clauses.joins.empty?
        raise ArgumentError.new(
          "delete_all deletes from one table; narrow with where_in instead of joins"
        )
      end
      table = T.__sugar_quoted_table
      sql = if @clauses.limit || @clauses.offset
              primary_key = %("#{T.__sugar_primary_key}")
              matching = "SELECT #{primary_key} FROM #{source}"
              "DELETE FROM #{table} WHERE #{primary_key} IN (#{matching})"
            else
              "DELETE FROM #{source(order: false)}"
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

    def sum_text(db : ::SugarORM::Handle, field : T::Field) : String
      ::SugarORM::Repo.using(db) { sum_text(field) }
    end

    def group_sum_text(db : ::SugarORM::Handle, by : T::Field, of : T::Field)
      ::SugarORM::Repo.using(db) { group_sum_text(by, of) }
    end

    {% for name in %w[min_text max_text avg_text group_count] %}
      def {{ name.id }}(db : ::SugarORM::Handle, field : T::Field)
        ::SugarORM::Repo.using(db) { {{ name.id }}(field) }
      end
    {% end %}

    def each_batch(db : ::SugarORM::Handle, size : Int32 = 1000, &)
      ::SugarORM::Repo.using(db) { each_batch(size) { |batch| yield batch } }
    end

    def page(db : ::SugarORM::Handle,
             size : Int32,
             after : Int64? = nil,
             direction : Symbol = :asc)
      ::SugarORM::Repo.using(db) { page(size, after, direction) }
    end

    # `Team::Query.where(...)` and friends start from an empty query.
    def self.where(fragment : String, *args)
      new.where(fragment, *args)
    end

    def self.order_by(field : T::Field, direction : Symbol = :asc)
      new.order_by(field, direction)
    end

    def self.sum_text(field : T::Field)
      new.sum_text(field)
    end

    def self.group_sum_text(by : T::Field, of : T::Field)
      new.group_sum_text(by, of)
    end

    {% for name in %w[min_text max_text avg_text group_count] %}
      def self.{{ name.id }}(field : T::Field)
        new.{{ name.id }}(field)
      end

      def self.{{ name.id }}(db : ::SugarORM::Handle, field : T::Field)
        new.{{ name.id }}(db, field)
      end
    {% end %}

    def self.each_batch(size : Int32 = 1000, &)
      new.each_batch(size) { |batch| yield batch }
    end

    def self.each_batch(db : ::SugarORM::Handle, size : Int32 = 1000, &)
      new.each_batch(db, size) { |batch| yield batch }
    end

    def self.page(size : Int32, after : Int64? = nil, direction : Symbol = :asc)
      new.page(size, after, direction)
    end

    def self.page(db : ::SugarORM::Handle,
                  size : Int32,
                  after : Int64? = nil,
                  direction : Symbol = :asc)
      new.page(db, size, after, direction)
    end

    def self.where_in(field : T::Field, parent : ::SugarORM::Query(U, Q)) forall U, Q
      new.where_in(field, parent)
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

    private def refuse_lock_with_joins : Nil
      return if @clauses.joins.empty? || !@clauses.lock
      raise ArgumentError.new(
        "a query with joins does not lock rows; narrow with where_in to lock them"
      )
    end

    # What `each_batch` and `page` refuse: a query that already orders or limits, and a size
    # that reads no row.
    private def refuse_keyset(terminal : String, size : Int32) : Nil
      unless @clauses.orders.empty? && @clauses.limit.nil? && @clauses.offset.nil?
        raise ArgumentError.new(
          "#{terminal} orders by the primary key and sets its own limit; " \
          "remove order_by, limit and offset from this query"
        )
      end
      raise ArgumentError.new("#{terminal} takes a size of at least 1") if size < 1
    end

    # This query past the cursor *after* (`>` ascending, `<` descending) in primary-key order,
    # limited to *count* rows.
    private def keyset(after : Int64?, direction : Symbol, count : Int32) : self
      key = %("#{T.__sugar_primary_key}")
      conditions = @clauses.conditions
      if after
        operator = direction == :asc ? ">" : "<"
        conditions += [::SugarORM::Condition.new("#{key} #{operator} ?", [after] of Value)]
      end
      order = "#{key} #{direction_sql(direction)}"
      clauses = @clauses.copy_with(conditions: conditions, orders: [order], limit: count)
      self.class.new(clauses, @preloads)
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

    private def source(order : Bool = true) : String
      String.build { |io| write_source(io, order) }
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

    # The FROM list, joins included, then the filters, numbering the `?` of both in one
    # sequence. With *numbered* false each fragment keeps its `?` binds, for a subquery whose
    # binds the enclosing query numbers in sequence with its own.
    private def write_source(io : IO, order : Bool, numbered : Bool = true) : Nil
      numbers = ::SugarORM::PlaceholderCounter.new
      io << T.__sugar_quoted_table
      @clauses.joins.each do |join|
        io << ' ' << (numbered ? numbers.number(join.sql) : join.sql)
      end
      write_filters(io, order, numbered, numbers)
    end

    private def write_filters(io : IO,
                              order : Bool,
                              numbered : Bool,
                              numbers : ::SugarORM::PlaceholderCounter) : Nil
      predicates = conditions
      unless predicates.empty?
        io << " WHERE "
        predicates.join(io, " AND ") do |condition, inner|
          inner << (numbered ? numbers.number(condition.sql) : condition.sql)
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
