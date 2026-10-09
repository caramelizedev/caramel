require "json"

module SugarORM
  # The contract for `field name : T, codec: C`. A codec for type `T` is any
  # type with these class methods:
  #
  #     def self.sql_type : String          # "numeric", "numeric(P,S)", "jsonb" or "text"
  #     def self.encode(value : T) : String
  #     def self.decode(text : String) : T
  #
  # `sql_type` uses PostgreSQL's `format_type` spelling, so the schema differ
  # compares it with the live column. Rows read a codec column as text
  # (`"col"::text`) and writes bind the encoded text, so a value never passes
  # through a float. A codec field takes no default, and `where` accepts a
  # value or nil for it. The changeset number validators do not apply to it,
  # because its encoded value is a String. `validate_inclusion` encodes its
  # list through the codec, so it takes values of the field's type.
  module Codec
    SQL_TYPE = /\A(?:numeric(?:\(([1-9]\d{0,3}),(\d{1,4})\))?|jsonb|text)\z/

    # Returns *type* when it is a column type a codec may name, with
    # `S <= P <= 1000` for `numeric(P,S)`.
    def self.checked_sql_type(type : String) : String
      if match = SQL_TYPE.match(type)
        precision = match[1]?
        scale = match[2]?
        return type unless precision && scale
        return type if scale.to_i <= precision.to_i && precision.to_i <= 1000
      end
      raise ArgumentError.new(
        "codec sql_type #{type.inspect} must be numeric, numeric(P,S), jsonb or text"
      )
    end
  end

  # Stores a JSON-serializable `T` (a `JSON::Serializable` type, `JSON::Any`,
  # or an `Array` or `Hash` of those) in a `jsonb` column:
  #
  #     field snapshot : Snapshot, codec: SugarORM::JSONB(Snapshot)
  struct JSONB(T)
    def self.sql_type : String
      "jsonb"
    end

    def self.encode(value : T) : String
      value.to_json
    end

    def self.decode(text : String) : T
      T.from_json(text)
    end
  end
end
