# Entities, stored with their aggregate.
module SweetTalk
  # An entity inside an aggregate: a row of the aggregate's child table, or a detached
  # fact inside an event.
  abstract class Entity < Model
    @__sweettalk_id : Int64? = nil

    # The constructors, facts, loading and saving, from the attributes declared so far.
    macro __sweettalk_storage
      {% attributes = @type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
           .map { |constant| @type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
      {% row = @type.constant("SWEETTALK_ROW").id %}
      {% foreign = "#{@type.constant("SWEETTALK_PARENT")[0].id}_id".id %}
      {% positional = [] of Nil %}
      {% loads = [] of Nil %}
      {% columns = [] of Nil %}
      {% facts = [] of Nil %}
      {% packs = [] of Nil %}
      {% for attribute, index in attributes %}
        {% name = attribute[0].id %}
        {% type = attribute[3].id %}
        {% trailing = true %}
        {% for later in attributes %}
          {% trailing = false if later[1] >= attribute[1] && !later[8] %}
        {% end %}
        {% if attribute[2] == "reference" %}
          {% positional << "#{name} : #{type} | #{type}::Id" %}
        {% elsif attribute[2] == "record" %}
          {% positional << "#{name} : #{type} | ::SweetTalk::RecordId(#{type})" %}
        {% else %}
          {% default = trailing && attribute[8] ? " = #{attribute[8].id}" : "" %}
          {% positional << "@#{name} : #{type}" + default %}
        {% end %}
        {% if attribute[2] == "value" %}
          {% loads << "@#{name} = #{type}.new(row.#{attribute[4].id})" %}
          {% columns << "#{attribute[4].id}: @#{name}.raw" %}
        {% elsif attribute[2] == "composite" %}
          {% parts = attribute[7].map do |part|
               read = "row.#{part[1].id}"
               "#{part[0].id}: " + (part[4] == "value" ? "#{part[3].id}.new(#{read.id})" : read)
             end %}
          {% loads << "@#{name} = #{type}.new(#{parts.join(", ").id})" %}
          {% for part in attribute[7] %}
            {% raw = part[4] == "value" ? ".raw" : "" %}
            {% columns << "#{part[1].id}: @#{name}.#{part[0].id}#{raw.id}" %}
          {% end %}
        {% else %}
          {% loads << "@#{attribute[4].id} = row.#{attribute[4].id}" %}
          {% columns << "#{attribute[4].id}: @#{attribute[4].id}" %}
        {% end %}
        {% if attribute[2] == "reference" || attribute[2] == "record" %}
          {% facts << "@#{attribute[4].id} = fact[#{attribute[4]}].as_i64" %}
          {% packs << "json.field(#{attribute[4]}, @#{attribute[4].id})" %}
        {% else %}
          {% facts << "@#{name} = ::SweetTalk.unpack(#{type}, fact[#{attribute[0]}])" %}
          {% packs << "json.field(#{attribute[0]}) { ::SweetTalk.pack(json, @#{name}) }" %}
        {% end %}
      {% end %}
      {% referring = attributes.select do |attribute|
           %w[reference record].includes?(attribute[2])
         end %}
      {% arguments = (["#{foreign}: #{foreign}"] + columns).join(", ") %}
      @__sweettalk_row : {{ row }}? = nil

      def initialize({{ positional.join(", ").id }})
        {% for attribute in referring %}
          @{{ attribute[4].id }} = ::SweetTalk.raw_id({{ attribute[0].id }})
        {% end %}
      end

      def initialize(*, stored row : {{ row }})
        @__sweettalk_row = row
        @__sweettalk_id = row.id
        {{ loads.join("\n").id }}
      end

      # A detached copy rebuilt from an event's facts; it has no row.
      def initialize(*, fact : JSON::Any)
        {{ facts.join("\n").id }}
      end

      def self.__sweettalk_unpack(any : JSON::Any) : self
        new(fact: any)
      end

      # Writes this entity's attributes as a fact.
      def __sweettalk_pack(json : JSON::Builder) : Nil
        json.object do
          {{ packs.join("\n").id }}
        end
      end

      # Inserts or updates this entity's row under its aggregate; returns its id.
      def __sweettalk_save(*, {{ foreign }} : Int64) : Int64
        changeset = if row = @__sweettalk_row
                      {{ row }}::Changeset.new(row, {{ arguments.id }})
                    else
                      {{ row }}::Changeset.new({{ arguments.id }})
                    end
        row ? ::SugarORM::Repo.update(changeset) : ::SugarORM::Repo.insert(changeset)
        raise ::SweetTalk::Refusal.new(changeset.error_messages.join("; ")) unless changeset.saved?
        @__sweettalk_row = changeset.record
        @__sweettalk_id = changeset.record.id
      end
    end
  end
end
