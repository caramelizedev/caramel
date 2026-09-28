require "../http/request_input"

module Caramel
  # The explicit, typed input of one action. Fields bind by name from route
  # parameters, the form body and the query; every other submitted form key
  # is rejected. Contracts only come from `parse`, and `handle` only ever
  # receives a valid one.
  abstract struct RequestContract
    getter errors = {} of String => Array(String)
    # Submitted text for each declared field, kept to re-render forms.
    getter values = {} of String => String

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
      return unless text.matches?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z/)
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
      {% source = "field #{decl}#{has_min ? ", min: #{min}".id : "".id}#{has_max ? ", max: #{max}".id : "".id}#{has_default ? ", default: #{default}".id : "".id}" %}
      {% where = decl.filename ? "\n  --> #{decl.filename.id}:#{decl.line_number}:#{decl.column_number}\n      #{source.id}" : "\n      #{source.id}" %}
      {% type = decl.type.resolve %}
      {% scalar = type %}
      {% nilable = false %}
      {% if type.union? %}
        {% members = type.union_types.reject { |member| member.id.stringify == "Nil" } %}
        {% if members.size != 1 || type.union_types.size != 2 %}
          {% decl.raise "unsupported Caramel::RequestContract field type: #{decl.type}#{where.id}" %}
        {% end %}
        {% scalar = members.first %}
        {% nilable = true %}
      {% end %}
      {% full = scalar.id.stringify %}
      {% unless ["String", "Int32", "Int64", "Float64", "Bool", "Time", "Caramel::UploadedFile"].includes?(full) %}
        {% decl.raise "unsupported Caramel::RequestContract field type: #{decl.type}#{where.id}" %}
      {% end %}
      {% short = full.split("::").last %}
      {% if (has_min || has_max) && !["String", "Int32", "Int64", "Float64"].includes?(full) %}
        {% decl.raise "min/max apply only to String, Int32, Int64 and Float64 fields: #{name}#{where.id}" %}
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
      {% unit = full == "String" ? " characters" : "" %}

      CARAMEL_FIELD_{{ name.upcase }} = { {{ name.stringify }}, {{ short }}, {{ nilable }}, {{ has_default }}, {{ summary }} }

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
          add_error("_base", {{ "Duplicate field: #{name}" }})
          return
        end
        {% if full == "Caramel::UploadedFile" %}
          if file = input.file?({{ name.stringify }})
            @{{ name }} = file
            return
          end
          raw = input.value?({{ name.stringify }})
          if raw && !raw.strip.empty?
            add_error({{ name.stringify }}, "must be a file")
            return
          end
          {% unless nilable %}
            add_error({{ name.stringify }}, "is required")
          {% end %}
        {% else %}
          raw = input.value?({{ name.stringify }})
          @values[{{ name.stringify }}] = raw if raw
          if raw.nil? || raw.strip.empty?
            {% if has_default %}
              @{{ name }} = {{ default }}
            {% elsif !nilable %}
              add_error({{ name.stringify }}, "is required")
            {% end %}
            return
          end
          value = ::Caramel::RequestContract.convert(raw, {{ scalar }})
          if value.nil?
            add_error({{ name.stringify }}, {{ "must be a valid #{short.id}" }})
            return
          end
          {% measure = full == "String" ? "value.size".id : "value".id %}
          {% if has_min %}
            if {{ measure }} < {{ min }}
              add_error({{ name.stringify }}, {{ "must be at least #{min}#{unit.id}" }})
              return
            end
          {% end %}
          {% if has_max %}
            if {{ measure }} > {{ max }}
              add_error({{ name.stringify }}, {{ "must be at most #{max}#{unit.id}" }})
              return
            end
          {% end %}
          @{{ name }} = value
        {% end %}
      end
    end

    macro inherited
      def self.parse(input : ::Caramel::RequestInput) : self
        contract = new
        input.errors.each do |field, messages|
          messages.each { |message| contract.add_error(field, message) }
        end
        {% verbatim do %}
          {% for constant in @type.constants %}
            {% if constant.stringify.starts_with?("CARAMEL_FIELD_") %}
              contract.__caramel_assign_{{ @type.constant(constant)[0].id }}(input)
            {% end %}
          {% end %}
        {% end %}
        input.strict_keys.each do |key|
          contract.add_error("_base", "Unknown field: #{key}") unless __caramel_field?(key)
        end
        contract
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
