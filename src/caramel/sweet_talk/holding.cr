# `entity`, the word an aggregate and an entity share to hold entities (ADR 0050).
module SweetTalk
  # Included by `Aggregate` and `Entity`: a model that holds entities in child tables.
  module Holding
    # `entity Line, means: "…" do … end` is an entity inside this aggregate or entity,
    # stored in a child table named after its parent, keyed by the parent's row, at any
    # depth. In a tenanted context the parent's key column may not be the tenant's.
    macro entity(name, means = nil, renamed_from = nil, &block)
      {% name.raise "#{@type.name.id}::#{name} needs a meaning: add means: \"…\", " +
                    "the line its glossary entry shows" if means.is_a?(NilLiteral) %}
      ::SweetTalk.__sweettalk_renamed({{ name }}, {{ renamed_from }})
      {% stored = (renamed_from || name).stringify.underscore %}
      {% table = "#{@type.constant("SWEETTALK_BASE").id}_#{stored.id}" %}
      {% parent = {@type.constant("SWEETTALK_STORED"), @type.constant("SWEETTALK_ROW")} %}
      {% home = ::SweetTalk::BoundedContext.includers
           .find { |context| @type.name.starts_with?("#{context.name}::") } %}
      {% tenant = home && home.constant("SWEETTALK_TENANT") %}
      {% if tenant && parent[0] == tenant[1] %}
        {% name.raise "entity #{name} would name its #{@type.constant("SWEETTALK_KIND").id} " +
                      "in #{tenant[1].id}_id, the column that names each row's tenant " +
                      "#{tenant[0].id}: rename #{@type.constant("SWEETTALK_KIND").id} " +
                      "#{@type.name.split("::").last.id}" %}
      {% end %}
      class {{ name }} < ::SweetTalk::Entity
        SWEETTALK_KIND   = "entity"
        SWEETTALK_MEANS  = {{ means }}
        SWEETTALK_ROW    = {{ "#{@type.constant("SWEETTALK_ROW").id}::#{name}" }}
        SWEETTALK_PARENT = {{ parent }}
        SWEETTALK_STORED = {{ stored }}
        SWEETTALK_BASE   = {{ table }}
        ::SweetTalk.__sweettalk_table({{ table }},
          {{ "entity #{@type.name.split("::").last.id}::#{name}" }})

        {{ block ? block.body : nil }}

        __sweettalk_storage
      end
    end
  end
end
