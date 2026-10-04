module Caramel::Tenancy
  # :nodoc:
  # Declares the tenant model, the String field its URLs name it by, and the
  # first segments of the central routes. `Caramel::Router.draw` passes the
  # model of its `tenant App::Account, by: :slug do … end` block, resolved in
  # the application's module; *at* is the block's source location.
  macro declare(model, *, by, central, at)
    {% at = "\n  --> #{at.id}" %}
    {% resolved = model.resolve? %}
    {% unless resolved && resolved < ::SugarORM::Schema %}
      {% raise "tenant #{model} must name a SugarORM schema, " +
               "like tenant App::Account, by: :slug do" + at %}
    {% end %}
    {% if resolved.has_constant?(:SUGAR_TENANT) %}
      {% raise "#{resolved} has a tenant itself; the tenant model cannot." + at %}
    {% end %}
    {% fields = resolved.constant(:SUGAR_FIELDS) %}
    {% strings = fields.keys.select { |name| fields[name][:declared] == "String" } %}
    {% names = strings.map(&.stringify) %}
    {% unless by.is_a?(SymbolLiteral) && names.includes?(by.id.stringify) %}
      {% raise "tenant #{resolved}, by: :#{by.id} must name a String field of #{resolved}. " +
               "Fields: #{strings.join(", ").id}" + at %}
    {% end %}

    module ::SugarORM::Tenancy
      # The tenant model the routes declare.
      alias Tenant = ::{{ resolved }}
      SCHEMA = {{ resolved.name.stringify }}
    end

    class ::Fiber
      # The tenant this fiber's statements are scoped to; set only by
      # SugarORM::Tenancy.bind.
      property __sugar_tenant : ::{{ resolved }}? = nil
    end

    module ::Caramel::Tenancy
      # :nodoc:
      # The first segments of the central routes, which no tenant's slug may
      # take.
      CENTRAL_SEGMENTS = [{{ central.splat }}] of String

      # :nodoc:
      def self.find(slug : String) : ::SugarORM::Tenancy::Tenant?
        ::SugarORM::Tenancy::Tenant.query.where({{ by.id }}: slug).first
      end

      # :nodoc:
      def self.find(id : Int64) : ::SugarORM::Tenancy::Tenant?
        ::SugarORM::Tenancy::Tenant.query.find(id)
      end

      # :nodoc:
      # The `/SLUG` segment that names *tenant*.
      def self.slug(tenant : ::SugarORM::Tenancy::Tenant) : String
        tenant.{{ by.id }}
      end
    end
  end
end
