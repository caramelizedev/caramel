# Values, typed ids and record ids, composite values, and their invariants.
module SweetTalk
  # A value object: a validated integer or string, rebuilt and so revalidated by every
  # arithmetic result. It is stored as a column of its raw type.
  abstract struct Value
    abstract def raw

    def self.raw_of(other : Int) : Int
      other
    end

    def self.raw_of(other : Value)
      other.raw
    end
  end

  # An aggregate's typed id, `Name::Id`, or a record's, `RecordId(Account)`.
  abstract struct Identity
    abstract def raw : Int64
  end

  # The id of a record of an application's own SugarORM schema, such as `Account`, that
  # an aggregate refers to with `has member : Account`.
  struct RecordId(T) < Identity
    getter raw : Int64

    def initialize(@raw : Int64)
    end

    # Reads the record.
    def load : T
      T.query.find!(raw)
    end

    def to_s(io : IO) : Nil
      io << raw
    end
  end

  # `never` and `always`, the invariants of an aggregate or a composite value.
  module Guarded
    # `never "message" { condition }` refuses any change that leaves the condition true.
    macro never(message, &block)
      private def __sweettalk_never_{{ message.line_number }} : Nil
        raise ::SweetTalk::Refusal.new({{ message }}) if ({{ block.body }})
      end
    end

    # `always "message" { condition }` refuses any change that leaves it false.
    macro always(message, &block)
      private def __sweettalk_always_{{ message.line_number }} : Nil
        raise ::SweetTalk::Refusal.new({{ message }}) unless ({{ block.body }})
      end
    end
  end

  # A value of several parts, such as an address: `value Address, means: "…" do part
  # street : String; … end`. It is equal to another with the same parts, checks its
  # `never` and `always` when it is built, and is stored one column per part.
  abstract struct Composite
    include Guarded

    # `part street : String` is one part: a column type, or a value that wraps one.
    # `SWEETTALK_PART_<NAME>` records {name, line, part type, raw column type, kind}.
    macro part(decl)
      {% unless decl.is_a?(TypeDeclaration) && decl.value.is_a?(Nop) %}
        {% decl.raise "part takes a name and a type, as in part street : String" %}
      {% end %}
      {% resolved = decl.type.resolve? %}
      {% if resolved && %w[String Int32 Int64 Bool Float64 Time].includes?(resolved.stringify) %}
        {% part = {decl.var.stringify, decl.line_number, resolved.stringify, resolved.stringify,
                   "column"} %}
      {% elsif resolved && resolved < ::SweetTalk::Value %}
        {% part = {decl.var.stringify, decl.line_number, "::#{resolved}",
                   resolved.constant("SWEETTALK_WRAPS"), "value"} %}
      {% else %}
        {% decl.raise "part #{decl} cannot be stored: a part is String, Int32, Int64, Bool, " +
                      "Float64, Time or a value that wraps one" %}
      {% end %}
      SWEETTALK_PART_{{ decl.var.id.upcase }} = {{ part }}

      getter {{ decl }}
    end

    # The constructor, the text, and the fact a composite value is written and read as,
    # from its parts.
    macro __sweettalk_storage
      {% parts = @type.constants.select(&.starts_with?("SWEETTALK_PART_"))
           .map { |constant| @type.constant(constant) }.sort_by { |part| part[1] } %}
      {% fields = parts.map { |part| "@#{part[0].id} : #{part[2].id}" }.join(", ") %}
      {% reads = parts.map do |part|
           "#{part[0].id}: ::SweetTalk.unpack(#{part[2].id}, any[#{part[0]}])"
         end %}
      def initialize(*, {{ fields.id }})
        __sweettalk_check
      end

      def to_s(io : IO) : Nil
        {% for part, index in parts %}
          {% if index > 0 %}
            io << ", "
          {% end %}
          io << @{{ part[0].id }}
        {% end %}
      end

      def __sweettalk_pack(json : JSON::Builder) : Nil
        json.object do
          {% for part in parts %}
            json.field({{ part[0] }}) { ::SweetTalk.pack(json, @{{ part[0].id }}) }
          {% end %}
        end
      end

      def self.__sweettalk_from_json(any : JSON::Any) : self
        new({{ reads.join(", ").id }})
      end
    end

    # Runs every `never` and `always` of this value.
    def __sweettalk_check : Nil
      {% for method in @type.methods %}
        {% if method.name.starts_with?("__sweettalk_never_") ||
                method.name.starts_with?("__sweettalk_always_") %}
          {{ method.name }}
        {% end %}
      {% end %}
    end
  end
end
