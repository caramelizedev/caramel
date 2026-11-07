module SugarORM
  # What an association accessor returns on a record that was not loaded with
  # `.preload(:name)`. Each schema generates `T::<Name>NotLoaded(Remediation)`,
  # which has no collection methods: any use is a compile error at the caller's
  # line whose type name carries the `.preload(:name)` remediation.
  abstract struct NotLoaded
  end

  # A record together with its preloaded associations. `L` is a NamedTuple from
  # association name to the loaded value. Schemas add one accessor per
  # association name that answers from `L` when present and otherwise falls
  # back to the record's NotLoaded sentinel.
  struct Loaded(T, L)
    getter record : T

    def initialize(@record : T, @loaded : L)
    end

    forward_missing_to @record
  end

  # Loads `T` rows whose `foreign_key` references each owner's primary key, of type `K`.
  struct HasMany(O, T, K)
    def initialize(@foreign_key : String)
    end

    def load(owners : Array(O)) : Array(Array(T))
      grouped = {} of K => Array(T)
      Associations.children(O, T, K, @foreign_key, owners) do |key, record|
        (grouped[key] ||= [] of T) << record
      end
      owners.map { |owner| grouped[owner.__sugar_primary_value]? || [] of T }
    end
  end

  # Loads the first `T` row (by primary key) whose `foreign_key` references each owner.
  # One row per owner comes back, not every child.
  struct HasOne(O, T, K)
    def initialize(@foreign_key : String)
    end

    def load(owners : Array(O)) : Array(T?)
      found = {} of K => T
      Associations.first_children(O, T, K, @foreign_key, owners) do |key, record|
        found[key] = record
      end
      owners.map { |owner| found[owner.__sugar_primary_value]? }
    end
  end

  # Loads the `T` row each owner references through its `column`. `V` is `T`
  # for a NOT NULL reference and `T?` for a nullable one; `K` is `T`'s key type.
  struct BelongsTo(O, T, V, K)
    def initialize(@column : String, &@key : O -> K?)
    end

    def load(owners : Array(O)) : Array(V)
      ids = owners.compact_map { |owner| @key.call(owner) }.uniq!
      found = {} of K => T
      unless ids.empty?
        args = [ids] of Value
        sql = "SELECT #{T.__sugar_select_list} FROM #{T.__sugar_quoted_table} " \
              "WHERE \"#{T.__sugar_primary_key}\" = ANY($1)" \
              "#{SugarORM.tenant_filter(T, args)}"
        Repo.query_all(sql, args) { |rows| T.from_row(rows) }.each do |record|
          found[record.__sugar_primary_value] = record
        end
      end
      owners.map do |owner|
        target = @key.call(owner).try { |id| found[id]? }
        {% if V.nilable? %}
          target
        {% else %}
          target || raise not_found(owner)
        {% end %}
      end
    end

    private def not_found(owner : O) : NotFound
      reference = "#{O}##{@column} = #{@key.call(owner)}"
      NotFound.new("#{T} referenced by #{reference} was not found")
    end
  end

  module Associations
    # One query for every child of `owners`, yielding `{foreign key, child}`.
    def self.children(owner : O.class,
                      target : T.class,
                      key_type : K.class,
                      foreign_key : String,
                      owners : Array(O),
                      & : K, T ->) : Nil forall O, T, K
      ids = owners.map(&.__sugar_primary_value).uniq!
      return if ids.empty?
      args = [ids] of Value
      sql = "SELECT \"#{foreign_key}\", #{T.__sugar_select_list} " \
            "FROM #{T.__sugar_quoted_table} " \
            "WHERE \"#{foreign_key}\" = ANY($1)#{SugarORM.tenant_filter(T, args)} " \
            "ORDER BY \"#{T.__sugar_primary_key}\""
      Repo.query(sql, args) do |rows|
        rows.each do
          key = rows.read(K?)
          record = T.from_row(rows)
          yield key, record if key
        end
      end
    end

    # One query for the lowest-keyed child of each of `owners`, yielding
    # `{foreign key, child}`: `DISTINCT ON` keeps one row per owner.
    def self.first_children(owner : O.class,
                            target : T.class,
                            key_type : K.class,
                            foreign_key : String,
                            owners : Array(O),
                            & : K, T ->) : Nil forall O, T, K
      ids = owners.map(&.__sugar_primary_value).uniq!
      return if ids.empty?
      args = [ids] of Value
      sql = "SELECT DISTINCT ON (\"#{foreign_key}\") \"#{foreign_key}\", " \
            "#{T.__sugar_select_list} FROM #{T.__sugar_quoted_table} " \
            "WHERE \"#{foreign_key}\" = ANY($1)#{SugarORM.tenant_filter(T, args)} " \
            "ORDER BY \"#{foreign_key}\", \"#{T.__sugar_primary_key}\""
      Repo.query(sql, args) do |rows|
        rows.each do
          key = rows.read(K?)
          record = T.from_row(rows)
          yield key, record if key
        end
      end
    end
  end
end
