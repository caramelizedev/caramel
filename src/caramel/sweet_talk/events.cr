# The event class an aggregate's and a context's `event` share.
module SweetTalk
  # Declares *name* as an event of the caller with its typed *fields* and the *carried*
  # {name, type} pairs an aggregate's `emit` reads. *channel* is its notification channel,
  # which fits PostgreSQL's 63 characters, or 42 in a program that requires
  # caramel/tenancy, which prefixes a tenant's `t<id>:`. *subject* is the aggregate it
  # belongs to, or nil for a context's event, whose subject is the bound tenant's id when
  # *tenanted*, and absent otherwise. A field named like the metadata, or like the
  # subject's id, is refused.
  macro __sweettalk_event(name, *fields, carried, channel, means, renamed_from, subject,
                          tenanted)
    {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                  "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
    ::SweetTalk.__sweettalk_renamed({{ name }}, {{ renamed_from }})
    {% owner = subject ? subject.names.last.underscore : nil %}
    {% reserved = %w[event_id occurred_at actor cause_id flow_id] %}
    {% reserved << "#{owner.id}_id" if owner %}
    {% names = [] of Nil %}
    {% types = [] of Nil %}
    {% for field in fields %}
      {% if reserved.includes?(field.var.stringify) %}
        {% field.raise "event #{name} cannot have a field named #{field.var}: " +
                       "SweetTalk records it" %}
      {% end %}
      {% names << field.var.stringify %}
      {% types << field.type.stringify %}
    {% end %}
    {% for pair in carried %}
      {% names << pair[0] %}
      {% types << pair[1] %}
    {% end %}
    {% parts = subject ? "context, aggregate or event" : "context or event" %}
    {% if ::Caramel.has_constant?("Tenancy") && channel.size > 42 %}
      {% name.raise "event #{name}'s channel #{channel.id} is longer than 42 characters: a " +
                    "tenant's t<id>: prefix adds up to 21 of PostgreSQL's 63; shorten the " +
                    "#{parts.id} name" %}
    {% elsif channel.size > 63 %}
      {% name.raise "event #{name}'s channel #{channel.id} is longer than PostgreSQL's 63 " +
                    "characters: shorten the #{parts.id} name" %}
    {% end %}
    {% given = names.map_with_index { |field, index| "@#{field.id} : #{types[index].id}" } %}
    {% given = given.join(", ") %}
    {% after_subject = names.empty? ? "" : ", *, #{given.id}" %}
    {% after_meta = names.empty? ? "" : ", #{given.id}" %}
    {% facts = names.map_with_index do |field, index|
         # A job queued before an optional field existed holds no such key: nil.
         key = "data[#{field.id.stringify}]"
         key = "(#{key.id}? || ::JSON::Any.new(nil))" if types[index] =~ /(\?|Nil)\z/
         "#{field.id}: ::SweetTalk.unpack(#{types[index].id}, #{key.id})"
       end %}
    class {{ name }} < ::SweetTalk::Event
      SWEETTALK_MEANS   = {{ means }}
      SWEETTALK_WAS     = {{ renamed_from ? renamed_from.stringify : nil }}
      SWEETTALK_CHANNEL = {{ channel }}
      SWEETTALK_CARRIES = [{{ carried.map(&.[0]).splat }}] of String

      {% for field, index in names %}
        getter {{ field.id }} : {{ types[index].id }}
      {% end %}

      {% if subject %}
        def initialize(subject : {{ subject }}{{ after_subject.id }})
          @__sweettalk_subject = subject
          __sweettalk_stamp
          @__sweettalk_fields = __sweettalk_record
        end

        def {{ owner.id }}_id : {{ subject }}::Id
          {{ subject }}::Id.new(@__sweettalk_subject_id || __sweettalk_subject.__sweettalk_raw_id)
        end
      {% else %}
        def initialize({{ names.empty? ? "".id : "*, #{given.id}".id }})
          {% if tenanted %}
            @__sweettalk_subject_id = ::Caramel::Tenancy.current?.try(&.__sugar_primary_value)
          {% end %}
          __sweettalk_stamp
          @__sweettalk_fields = __sweettalk_record
        end
      {% end %}

      def initialize(*, subject_id : Int64?, fields_json : String,
                     meta_json : String{{ after_meta.id }})
        @__sweettalk_subject_id = subject_id
        @__sweettalk_fields = fields_json
        __sweettalk_restore(meta_json)
      end

      def __sweettalk_channel : String
        SWEETTALK_CHANNEL
      end

      private def __sweettalk_record : String
        JSON.build do |json|
          json.object do
            {% for field in names %}
              json.field({{ field.id.stringify }}) { ::SweetTalk.pack(json, @{{ field.id }}) }
            {% end %}
          end
        end
      end

      def self.__sweettalk_load(subject : Int64?, fields : String, meta : String) : self
        {% if names.empty? %}
          new(subject_id: subject, fields_json: fields, meta_json: meta)
        {% else %}
          data = JSON.parse(fields)
          new(subject_id: subject, fields_json: fields, meta_json: meta,
            {{ facts.join(", ").id }})
        {% end %}
      end
    end
  end
end
