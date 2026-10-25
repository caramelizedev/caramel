# Facts: how attributes, query conditions and event fields become columns and JSON,
# and back.
module SweetTalk
  # `the name : Type = expression` returns the expression as the declared type, building
  # it with `Type.new` when it is not one already.
  def self.coerce(type : T.class, value : T) : T forall T
    value
  end

  def self.coerce(type : T.class, value) : T forall T
    T.new(value)
  end

  # The raw id behind an aggregate, its typed id or an application's schema record, for a
  # reference's column.
  def self.raw_id(target : Aggregate) : Int64
    target.__sweettalk_raw_id
  end

  def self.raw_id(target : Identity) : Int64
    target.raw
  end

  def self.raw_id(record : ::SugarORM::Schema) : Int64
    record.__sugar_primary_value
  end

  # An optional reference that is not set stores no id.
  def self.raw_id(target : Nil) : Nil
    nil
  end

  # The value a query compares a column with: a value's raw, an id's number, an
  # aggregate's or a record's id, and lists and ranges of them.
  def self.column(value : Value)
    value.raw
  end

  def self.column(value : Identity) : Int64
    value.raw
  end

  def self.column(value : Aggregate) : Int64
    value.__sweettalk_raw_id
  end

  def self.column(value : ::SugarORM::Schema) : Int64
    value.__sugar_primary_value
  end

  def self.column(value : Array)
    value.map { |item| column(item) }
  end

  def self.column(value : Range)
    Range.new(column(value.begin), column(value.end), value.excludes_end?)
  end

  def self.column(value : (String | Int32 | Int64 | Bool | Float64 | Time)?)
    value
  end

  # Writes one fact as JSON: a value as its raw, an id as its number, an entity or a
  # composite value as an object, nil as null.
  def self.pack(json : JSON::Builder, value : Value) : Nil
    value.raw.to_json(json)
  end

  def self.pack(json : JSON::Builder, value : Identity) : Nil
    json.number(value.raw)
  end

  def self.pack(json : JSON::Builder, value : Entity | Composite) : Nil
    value.__sweettalk_pack(json)
  end

  def self.pack(json : JSON::Builder, value : Array) : Nil
    json.array { value.each { |item| pack(json, item) } }
  end

  def self.pack(json : JSON::Builder, value : String | Int32 | Int64 | Bool | Float64 | Time) : Nil
    value.to_json(json)
  end

  def self.pack(json : JSON::Builder, value : Nil) : Nil
    json.null
  end

  # Reads one fact back from JSON.
  def self.unpack(type : T.class, any : JSON::Any) : T forall T
    {% if T.nilable? || T.union? %}
      {% members = T.union_types.reject { |member| member == Nil } %}
      {% unless T.nilable? && members.size == 1 %}
        {% raise "an event field may be nilable, as in reason : String?, but not a union " +
                 "of other types" %}
      {% end %}
      any.raw.nil? ? nil : unpack({{ members[0] }}, any)
    {% elsif T < ::SweetTalk::Value || T < ::SweetTalk::Composite %}
      T.__sweettalk_from_json(any)
    {% elsif T < ::SweetTalk::Identity %}
      T.new(any.as_i64)
    {% elsif T < ::SweetTalk::Entity %}
      T.__sweettalk_unpack(any)
    {% elsif T.name(generic_args: false).stringify == "Array" %}
      any.as_a.map { |item| unpack({{ T.type_vars[0] }}, item) }
    {% elsif T == String %}
      any.as_s
    {% elsif T == Int32 %}
      any.as_i
    {% elsif T == Int64 %}
      any.as_i64
    {% elsif T == Bool %}
      any.as_bool
    {% elsif T == Float64 %}
      any.as_f
    {% elsif T == Time %}
      Time.parse_rfc3339(any.as_s)
    {% else %}
      {% raise "an event field holds String, Int32, Int64, Bool, Float64, Time, a value, " +
               "an id or an Array of an entity, not #{T}" %}
    {% end %}
  end
end
