module Caramel
  # Include generated paths in the application's action base. IDs are
  # explicit Int64 values; an unsaved record must be checked before linking it.
  macro resource_paths(plural, singular)
    {% plural_name = plural.id.stringify %}
    {% singular_name = singular.id.stringify %}
    {% unless plural_name =~ /^[a-z][a-z0-9_]*$/ && singular_name =~ /^[a-z][a-z0-9_]*$/ %}
      {% raise "resource path names must be lowercase identifiers" %}
    {% end %}
    def {{plural.id}}_path : String
      {{"/#{plural.id}"}}
    end

    def {{singular.id}}_path(id : Int64) : String
      raise ArgumentError.new("record ID must be positive") unless id > 0
      {{"/#{plural.id}/"}} + id.to_s
    end

    def new_{{singular.id}}_path : String
      {{"/#{plural.id}/new"}}
    end

    def edit_{{singular.id}}_path(id : Int64) : String
      {{singular.id}}_path(id) + "/edit"
    end
  end
end
