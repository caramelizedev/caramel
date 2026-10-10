# The SugarORM schema and changeset of each stored kind.
module SweetTalk
  # The SugarORM schema and changeset for one aggregate, entity or projection.
  macro __sweettalk_schema(owner)
    {% type = owner.resolve %}
    {% row = type.constant("SWEETTALK_ROW").id %}
    {% attributes = type.constants.select(&.starts_with?("SWEETTALK_HAS_"))
         .map { |constant| type.constant(constant) }.sort_by { |attribute| attribute[1] } %}
    {% parent = type.has_constant?("SWEETTALK_PARENT") ? type.constant("SWEETTALK_PARENT") : nil %}
    {% moves = type.has_constant?("SWEETTALK_MOVES") ? type.constant("SWEETTALK_MOVES") : nil %}
    {% named = type.has_constant?("SWEETTALK_KEY") ? type.constant("SWEETTALK_KEY") : nil %}
    {% key = named ? attributes.find { |attribute| attribute[0] == named } : nil %}
    {% indexed = key && (key[2] == "composite" ? key[7].map { |part| part[1] } : [key[4]]) %}
    {% aggregate = type < ::SweetTalk::Aggregate %}
    struct {{ row }} < ::SugarORM::Schema
      schema {{ type.constant("SWEETTALK_TABLE") }} do
        field id : Int64, primary: true
        {% if parent %}
          belongs_to {{ parent[0].id }} : {{ parent[1].id }}
        {% end %}
        {% for attribute in attributes %}
          {{ attribute[5].id }}
        {% end %}
        {% if moves %}
          field state : String = {{ moves[0] }}
        {% end %}
        {% if aggregate %}
          field removed_at : Time?
        {% end %}
        {% if key %}
          index {{ indexed.map { |column| ":#{column.id}" }.join(", ").id }}, unique: true
        {% end %}
        timestamps
      end
    end

    class {{ row }}::Changeset < ::SugarORM::Changeset({{ row }})
      {% if parent %}
        param {{ parent[0].id }}_id : Int64
      {% end %}
      {% for attribute in attributes %}
        {% if attribute[2] == "composite" %}
          {% for part in attribute[7] %}
            param {{ part[1].id }} : {{ part[2].id }}
          {% end %}
        {% elsif attribute[2] != "entities" %}
          param {{ attribute[4].id }} : {{ attribute[6].id }}
        {% end %}
      {% end %}
      {% if moves %}
        param state : String
      {% end %}
      {% if aggregate %}
        param removed_at : Time?
      {% end %}
    end
  end
end
