require "../http/request_input"
require "../wording"

module Caramel
  # The explicit, typed input of one action. Fields bind by name from route
  # parameters, the form or JSON body and the query; every other submitted
  # key is rejected. A JSON member must have its field's JSON type.
  # Contracts only come from `parse`, and `handle` only ever receives a
  # valid one.
  abstract struct RequestContract
    # The JSON type a member must have to bind each field type, and its name
    # in the error when it does not.
    JSON_TYPES = {
      "String"  => {"String", "string"},
      "Time"    => {"String", "string"},
      "Int32"   => {"Number", "number"},
      "Int64"   => {"Number", "number"},
      "Float64" => {"Number", "number"},
      "Bool"    => {"Bool", "boolean"},
    }

    # An RFC 3339 timestamp with seconds and a zone, such as
    # `2026-09-30T08:00:00Z` or `2026-09-30T10:00:00.5+02:00`.
    RFC3339_TIME = /\A
      [0-9]{4}-[0-9]{2}-[0-9]{2}
      T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?
      (?:Z|[+-][0-9]{2}:[0-9]{2})
    \z/x

    getter errors = {} of String => Array(String)
    # Submitted text for each declared field, kept to re-render forms.
    getter values = {} of String => String
    # Submitted text for each declared Array field, kept to re-render forms.
    getter lists = {} of String => Array(String)

    def valid? : Bool
      @errors.empty?
    end

    def add_error(field : String, message : String) : Nil
      (@errors[field] ||= [] of String) << message
    end

    def route_error?(names : Array(String)) : Bool
      names.any? { |name| @errors.has_key?(name) }
    end

    # Machine-readable diagnostics for clients that accept neither JSON nor HTML.
    def to_mrdp(method : String, path : String) : String
      String.build do |io|
        io << "ERR CONTRACT_INVALID:422 at " << method << ' ' << path << '\n'
        @errors.each do |field, messages|
          messages.each { |message| io << "FIELD " << field << ": " << message << '\n' }
        end
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
      end
    end

    def self.convert(text : String, type : Float64.class) : Float64?
      return unless text.matches?(/\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/)
      value = text.to_f64?
      value && value.finite? ? value : nil
    end

    def self.convert(text : String, type : Time.class) : Time?
      return unless text.matches?(RFC3339_TIME)
      Time.parse_rfc3339(text).to_utc
    rescue Time::Format::Error | ArgumentError
      nil
    end

    # Files never come from text; this overload exists only for typing.
    def self.convert(text : String, type : UploadedFile.class) : UploadedFile?
      nil
    end

    macro field(decl, min = nil, max = nil, default = nil)
      {% name = decl.var.id %}
      {% has_min = !min.is_a?(NilLiteral) %}
      {% has_max = !max.is_a?(NilLiteral) %}
      {% has_default = !default.is_a?(NilLiteral) %}
      # Crystal reports a raise inside a type body at the enclosing type's
      # name, so each message carries the declaration and its location.
      {% min_text = has_min ? ", min: #{min}" : "" %}
      {% max_text = has_max ? ", max: #{max}" : "" %}
      {% default_text = has_default ? ", default: #{default}" : "" %}
      {% source = "field #{decl}#{min_text.id}#{max_text.id}#{default_text.id}" %}
      {% where = "\n      #{source.id}" %}
      {% if decl.filename %}
        {% position = "#{decl.line_number}:#{decl.column_number}" %}
        {% where = "\n  --> #{decl.filename.id}:#{position.id}" + where %}
      {% end %}
      {% unsupported = "unsupported Caramel::RequestContract field type: " +
                       "#{decl.type}#{where.id}" %}
      {% type = decl.type.resolve %}
      {% element_types = ["String", "Int32", "Int64", "Float64", "Bool", "Time"] %}
      {% if !type.union? && type.name(generic_args: false).stringify == "Array" &&
              type.type_vars.size == 1 &&
              element_types.includes?(type.type_vars.first.id.stringify) %}
        __caramel_array_field({{ decl }}, {{ min }}, {{ max }}, {{ default }}, {{ where }})
      {% else %}
      {% scalar = type %}
      {% nilable = false %}
      {% if type.union? %}
        {% members = type.union_types.reject { |member| member.id.stringify == "Nil" } %}
        {% if members.size != 1 || type.union_types.size != 2 %}
          {% decl.raise unsupported %}
        {% end %}
        {% scalar = members.first %}
        {% nilable = true %}
      {% end %}
      {% full = scalar.id.stringify %}
      {% supported = ["String", "Int32", "Int64", "Float64", "Bool", "Time",
                      "Caramel::UploadedFile"] %}
      {% unless supported.includes?(full) %}
        {% decl.raise unsupported %}
      {% end %}
      {% short = full.split("::").last %}
      {% bounded = ["String", "Int32", "Int64", "Float64"] %}
      {% if (has_min || has_max) && !bounded.includes?(full) %}
        {% decl.raise "min/max apply only to String, Int32, Int64 and Float64 fields: " +
                      "#{name}#{where.id}" %}
      {% end %}
      {% if has_default && full == "Caramel::UploadedFile" %}
        {% decl.raise "UploadedFile fields cannot declare defaults: #{name}#{where.id}" %}
      {% end %}
      {% summary = "#{name}:#{short.id}#{nilable ? "?".id : "".id}" %}
      {% if has_min && has_max %}
        {% summary = summary + "(min=#{min},max=#{max})" %}
      {% elsif has_min %}
        {% summary = summary + "(min=#{min})" %}
      {% elsif has_max %}
        {% summary = summary + "(max=#{max})" %}
      {% end %}

      CARAMEL_FIELD_{{ name.upcase }} = {
        {{ name.stringify }}, {{ short }}, {{ nilable }}, {{ has_default }}, {{ summary }},
      }

      @{{ name }} : {{ scalar }}? = nil

      def {{ name }} : {{ decl.type }}
        {% if nilable %}
          @{{ name }}
        {% else %}
          @{{ name }}.as({{ scalar }})
        {% end %}
      end

      def __caramel_assign_{{ name }}(input : ::Caramel::RequestInput) : Nil
        if input.source_count({{ name.stringify }}) > 1
          add_error("_base", ::Caramel::Wording.duplicate_field({{ name.stringify }}))
          return
        end
        {% if full == "Caramel::UploadedFile" %}
          if file = input.file?({{ name.stringify }})
            @{{ name }} = file
            return
          end
          raw = input.value?({{ name.stringify }})
          if raw && !raw.strip.empty?
            add_error({{ name.stringify }}, ::Caramel::Wording.must_be_file)
            return
          end
          {% unless nilable %}
            add_error({{ name.stringify }}, ::Caramel::Wording.required)
          {% end %}
        {% else %}
          {% json = ::Caramel::RequestContract::JSON_TYPES[full] %}
          json = ::Caramel::RequestInput::JsonKind::{{ json[0].id }}
          if input.json_mismatch?({{ name.stringify }}, json)
            add_error({{ name.stringify }}, ::Caramel::Wording.json_type({{ json[1] }}))
            return
          end
          raw = input.value?({{ name.stringify }})
          @values[{{ name.stringify }}] = raw if raw
          if raw.nil? || raw.strip.empty?
            {% if has_default %}
              @{{ name }} = {{ default }}
            {% elsif !nilable %}
              add_error({{ name.stringify }}, ::Caramel::Wording.required)
            {% end %}
            return
          end
          value = ::Caramel::RequestContract.convert(raw, {{ scalar }})
          if value.nil?
            add_error({{ name.stringify }}, ::Caramel::Wording.invalid_value({{ short }}))
            return
          end
          {% measure = full == "String" ? "value.size".id : "value".id %}
          {% at_least = full == "String" ? "at_least_characters".id : "at_least".id %}
          {% at_most = full == "String" ? "at_most_characters".id : "at_most".id %}
          {% if has_min %}
            if {{ measure }} < {{ min }}
              add_error({{ name.stringify }}, ::Caramel::Wording.{{ at_least }}({{ min }}))
              return
            end
          {% end %}
          {% if has_max %}
            if {{ measure }} > {{ max }}
              add_error({{ name.stringify }}, ::Caramel::Wording.{{ at_most }}({{ max }}))
              return
            end
          {% end %}
          @{{ name }} = value
        {% end %}
      end
      {% end %}
    end

    # An `Array(T)` field of a scalar type: bounded by `max:` and optionally
    # `min:`, each item converted like a field of its type.
    macro __caramel_array_field(decl, min, max, default, where)
      {% name = decl.var.id %}
      {% has_min = !min.is_a?(NilLiteral) %}
      {% has_max = !max.is_a?(NilLiteral) %}
      {% element = decl.type.resolve.type_vars.first %}
      {% full = element.id.stringify %}
      {% unless has_max %}
        {% decl.raise "array fields must declare max:, the most items they accept: " +
                      "#{name}#{where.id}" %}
      {% end %}
      {% unless default.is_a?(NilLiteral) %}
        {% decl.raise "array fields take no default; an absent array is empty: " +
                      "#{name}#{where.id}" %}
      {% end %}
      {% min_value = has_min ? min : 0 %}
      {% bounds_ok = max.is_a?(NumberLiteral) && !max.kind.stringify.includes?("f") &&
                     min_value.is_a?(NumberLiteral) &&
                     !min_value.kind.stringify.includes?("f") &&
                     max >= 1 && min_value >= 0 && min_value <= max %}
      {% unless bounds_ok %}
        {% decl.raise "array bounds must be integer literals with 0 <= min <= max and " +
                      "max >= 1: #{name}#{where.id}" %}
      {% end %}
      {% json = ::Caramel::RequestContract::JSON_TYPES[full] %}
      {% bounds = has_min ? "min=#{min},max=#{max}" : "max=#{max}" %}

      CARAMEL_FIELD_{{ name.upcase }} = {
        {{ name.stringify }}, {{ "Array(#{full.id})" }}, false, false,
        {{ "#{name}:Array(#{full.id})(#{bounds.id})" }},
      }

      @{{ name }} : Array({{ element }})? = nil

      def {{ name }} : Array({{ element }})
        @{{ name }}.as(Array({{ element }}))
      end

      def __caramel_assign_{{ name }}(input : ::Caramel::RequestInput) : Nil
        if input.source_count({{ name.stringify }}) > 1
          add_error("_base", ::Caramel::Wording.duplicate_field({{ name.stringify }}))
          return
        end
        items = [] of {String?, ::Caramel::RequestInput::JsonKind?}
        kind = input.json_kind?({{ name.stringify }})
        if kind.nil?
          input.all_values({{ name.stringify }}).each { |text| items << {text, nil} }
        elsif kind.array?
          input.json_items({{ name.stringify }}).each { |item| items << {item[0], item[1]} }
        elsif !kind.null?
          add_error({{ name.stringify }}, ::Caramel::Wording.json_type("array"))
          return
        end
        @lists[{{ name.stringify }}] = items.map { |item| item[0] || "" }
        if items.size > {{ max }}
          add_error({{ name.stringify }}, ::Caramel::Wording.at_most_items({{ max }}))
          return
        end
        {% if min_value > 0 %}
          if items.size < {{ min_value }}
            add_error({{ name.stringify }}, ::Caramel::Wording.at_least_items({{ min_value }}))
            return
          end
        {% end %}
        values = [] of {{ element }}
        seen = Set({{ element }}).new
        failed = false
        items.each_with_index do |(text, item_kind), index|
          key = "#{{{ name.stringify }}}[#{index}]"
          expected = ::Caramel::RequestInput::JsonKind::{{ json[0].id }}
          if item_kind && !item_kind.null? && item_kind != expected
            add_error(key, ::Caramel::Wording.json_type({{ json[1] }}))
            failed = true
            next
          end
          if text.nil? || text.strip.empty?
            add_error(key, ::Caramel::Wording.required)
            failed = true
            next
          end
          value = ::Caramel::RequestContract.convert(text, {{ element }})
          if value.nil?
            add_error(key, ::Caramel::Wording.invalid_value({{ full.split("::").last }}))
            failed = true
            next
          end
          unless seen.add?(value)
            add_error(key, ::Caramel::Wording.duplicate_item)
            failed = true
            next
          end
          values << value
        end
        @{{ name }} = values unless failed
      end
    end

    macro inherited
      def self.parse(input : ::Caramel::RequestInput) : self
        contract = new
        input.errors.each do |field, messages|
          messages.each { |message| contract.add_error(field, message) }
        end
        input.repeated_names.each do |key|
          next if __caramel_array_field?(key)
          contract.add_error("_base", ::Caramel::Wording.duplicate_field(key))
        end
        {% verbatim do %}
          {% for constant in @type.constants %}
            {% if constant.stringify.starts_with?("CARAMEL_FIELD_") %}
              contract.__caramel_assign_{{ @type.constant(constant)[0].id }}(input)
            {% end %}
          {% end %}
        {% end %}
        input.strict_keys.each do |key|
          next if __caramel_field?(key)
          contract.add_error("_base", ::Caramel::Wording.unknown_field(key))
        end
        contract
      end

      private def self.__caramel_array_field?(key : String) : Bool
        {% verbatim do %}
          {% for constant in @type.constants %}
            {% if constant.stringify.starts_with?("CARAMEL_FIELD_") %}
              {% field = @type.constant(constant) %}
              {% if field[1].starts_with?("Array(") %}
                return true if key == {{ field[0] }}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        false
      end

      private def self.__caramel_field?(key : String) : Bool
        {% verbatim do %}
          {% for constant in @type.constants %}
            {% if constant.stringify.starts_with?("CARAMEL_FIELD_") %}
              return true if key == {{ @type.constant(constant)[0] }}
            {% end %}
          {% end %}
        {% end %}
        false
      end
    end
  end
end
