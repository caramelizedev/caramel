require "../wording"

module Caramel
  # *path* under the request tenant's prefix, unless *resource* is a
  # central route's first segment. `caramel/tenancy` adds the prefix.
  def self.tenant_path(path : String, of resource : String? = nil) : String
    path
  end

  # Include generated paths in the application's action base. IDs are
  # explicit Int64 values; an unsaved record must be checked before linking it.
  # Each path passes through `Caramel.localize_path`, so with `caramel/i18n`
  # it carries the request's locale prefix, and through `Caramel.tenant_path`,
  # so with `caramel/tenancy` it carries the request tenant's.
  macro resource_paths(plural, singular)
    {% plural_name = plural.id.stringify %}
    {% singular_name = singular.id.stringify %}
    {% unless plural_name =~ /^[a-z][a-z0-9_]*$/ && singular_name =~ /^[a-z][a-z0-9_]*$/ %}
      {% raise "resource path names must be lowercase identifiers" %}
    {% end %}
    def {{ plural.id }}_path : String
      path = ::Caramel.localize_path({{ "/#{plural.id}" }})
      ::Caramel.tenant_path(path, of: {{ plural_name }})
    end

    def {{ singular.id }}_path(id : Int64) : String
      raise ArgumentError.new("record ID must be positive") unless id > 0
      path = ::Caramel.localize_path({{ "/#{plural.id}/" }} + id.to_s)
      ::Caramel.tenant_path(path, of: {{ plural_name }})
    end

    def new_{{ singular.id }}_path : String
      path = ::Caramel.localize_path({{ "/#{plural.id}/new" }})
      ::Caramel.tenant_path(path, of: {{ plural_name }})
    end

    # Built from the plural path, not the record path, which already
    # carries the prefixes.
    def edit_{{ singular.id }}_path(id : Int64) : String
      raise ArgumentError.new("record ID must be positive") unless id > 0
      path = ::Caramel.localize_path({{ "/#{plural.id}/" }} + id.to_s + "/edit")
      ::Caramel.tenant_path(path, of: {{ plural_name }})
    end
  end
end
