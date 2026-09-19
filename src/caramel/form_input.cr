require "./form"

module Caramel
  # Explicitly declared browser inputs, separate from database records. Parsing
  # does not authorize a mutation; controllers verify CSRF before returning a
  # result, and applications still authorize access to records.
  module FormInput
    class Result(T)
      getter value : T?
      getter errors : Hash(String, Array(String))
      getter values : Hash(String, String)

      def initialize(@value, @errors, @values)
      end

      def valid? : Bool
        !@value.nil? && @errors.empty?
      end
    end

    # Conversions deliberately accept a small, documented wire grammar. Crystal
    # literal conveniences such as numeric underscores are not browser inputs.
    def self.convert(text : String, type : String.class) : String
      text
    end

    def self.convert(text : String, type : Int32.class) : Int32?
      text.matches?(/\A[+-]?[0-9]+\z/) ? text.to_i32? : nil
    end

    def self.convert(text : String, type : Int64.class) : Int64?
      text.matches?(/\A[+-]?[0-9]+\z/) ? text.to_i64? : nil
    end

    def self.convert(text : String, type : Bool.class) : Bool?
      case text
      when "true"  then true
      when "false" then false
      else              nil
      end
    end

    def self.convert(text : String, type : Float64.class) : Float64?
      return nil unless text.matches?(/\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/)
      value = text.to_f64?
      value && value.finite? ? value : nil
    end

    def self.convert(text : String, type : Time.class) : Time?
      return nil unless text.matches?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z/)
      Time.parse_rfc3339(text).to_utc
    rescue Time::Format::Error | ArgumentError
      nil
    end

    macro field(declaration)
      {% type = declaration.type.resolve %}
      {% scalar = type %}
      {% if type.union? %}
        {% members = type.union_types.reject { |member| member.id.stringify == "Nil" } %}
        {% if members.size != 1 || type.union_types.size != 2 %}
          {% raise "FormInput fields require one supported scalar type, optionally nullable" %}
        {% end %}
        {% scalar = members.first %}
      {% end %}
      {% unless ["String", "Int32", "Int64", "Bool", "Float64", "Time"].includes?(scalar.id.stringify) %}
        {% raise "unsupported Caramel::FormInput field type: #{declaration.type}" %}
      {% end %}
      FIELD_{{declaration.var.id.upcase}} = true
      getter {{declaration}}
    end

    macro form_envelope(name)
      FORM_ENVELOPE = {{name}}
    end

    macro __caramel_input_initialize(attributes)
      {% for ivar in @type.instance_vars %}
        {% if @type.constant("FIELD_#{ivar.name.id.upcase}".id) %}
          {% if ivar.type.nilable? %}
            @{{ivar.name}} = {{attributes}}[{{ivar.name.stringify}}]?
          {% else %}
            @{{ivar.name}} = {{attributes}}[{{ivar.name.stringify}}]
          {% end %}
        {% end %}
      {% end %}
    end

    macro __caramel_input_fields(required_only)
      [
        {% for ivar in @type.instance_vars %}
          {% if @type.constant("FIELD_#{ivar.name.id.upcase}".id) && (!required_only || !ivar.type.nilable?) %}
            {{ivar.name.stringify}},
          {% end %}
        {% end %}
      ] of String
    end

    macro __caramel_input_parse(form)
      errors = {{form}}.field_errors.transform_values(&.dup)
      values = {{form}}.values.dup
      {% fields = @type.instance_vars.select { |ivar| @type.constant("FIELD_#{ivar.name.id.upcase}".id) } %}
      {% for ivar in fields %}
        {% scalar = ivar.type.nilable? ? ivar.type.union_types.reject { |member| member.id.stringify == "Nil" }.first : ivar.type %}
        raw_{{ivar.name}} = values[{{ivar.name.stringify}}]?
        parsed_{{ivar.name}} = nil.as({{scalar}}?)
        if text = raw_{{ivar.name}}
          {% if ivar.type.nilable? %}
            unless text.strip.empty?
          {% end %}
          parsed_{{ivar.name}} = Caramel::FormInput.convert(text, {{scalar}})
          if parsed_{{ivar.name}}.nil?
            (errors[{{ivar.name.stringify}}] ||= [] of String) << "must be a valid {{scalar.id}}"
          end
          {% if ivar.type.nilable? %}
            end
          {% end %}
        {% unless ivar.type.nilable? %}
        else
          errors[{{ivar.name.stringify}}] ||= ["Missing {{ivar.name}}"]
        {% end %}
        end
      {% end %}
      value = if errors.empty?
        new(
          {% for ivar in fields %}
            {{ivar.name}}: parsed_{{ivar.name}}{% unless ivar.type.nilable? %}.not_nil!{% end %},
          {% end %}
        )
      end
      Caramel::FormInput::Result(self).new(value, errors, values)
    end

    macro included
      def initialize(**attributes : **U) forall U
        {% verbatim do %}
          {% for key in U.type_vars[0].keys %}
            {% unless @type.constant("FIELD_#{key.id.upcase}".id) %}
              {% raise "unknown Caramel::FormInput constructor field: #{key}" %}
            {% end %}
          {% end %}
        {% end %}
        __caramel_input_initialize(attributes)
      end

      def self.envelope : String
        {% verbatim do %}
          {% if name = @type.constant(:FORM_ENVELOPE) %}
            {{name}}
          {% else %}
            {{@type.name.stringify.split("::").last.gsub(/Input$/, "").underscore}}
          {% end %}
        {% end %}
      end

      def self.fields : Array(String)
        __caramel_input_fields(false)
      end

      def self.required_fields : Array(String)
        __caramel_input_fields(true)
      end

      def self.from_form(form : Caramel::Form) : Caramel::FormInput::Result(self)
        __caramel_input_parse(form)
      end
    end
  end
end
