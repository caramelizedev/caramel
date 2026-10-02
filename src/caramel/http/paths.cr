require "../wording"

module Caramel
  # Include generated paths in the application's action base. IDs are
  # explicit Int64 values; an unsaved record must be checked before linking it.
  # Each path passes through `Caramel.localize_path`, so with `caramel/i18n`
  # it carries the request's locale prefix.
  macro resource_paths(plural, singular)
    {% plural_name = plural.id.stringify %}
    {% singular_name = singular.id.stringify %}
    {% unless plural_name =~ /^[a-z][a-z0-9_]*$/ && singular_name =~ /^[a-z][a-z0-9_]*$/ %}
      {% raise "resource path names must be lowercase identifiers" %}
    {% end %}
    def {{ plural.id }}_path : String
      ::Caramel.localize_path({{ "/#{plural.id}" }})
    end

    def {{ singular.id }}_path(id : Int64) : String
      raise ArgumentError.new("record ID must be positive") unless id > 0
      ::Caramel.localize_path({{ "/#{plural.id}/" }} + id.to_s)
    end

    def new_{{ singular.id }}_path : String
      ::Caramel.localize_path({{ "/#{plural.id}/new" }})
    end

    # Built from the plural path, not the record path, which already
    # carries the prefix.
    def edit_{{ singular.id }}_path(id : Int64) : String
      raise ArgumentError.new("record ID must be positive") unless id > 0
      ::Caramel.localize_path({{ "/#{plural.id}/" }} + id.to_s + "/edit")
    end
  end
end
