require "../caramel"
require "../sugar_orm/tenancy"
require "./tenancy/declaration"
require "./tenancy/runtime"
require "./tenancy/tenanted"

module Caramel::Tenancy
  # `require "caramel/tenancy"` scopes tenanted schemas to the tenant the
  # routes declare, so an application that requires it must declare one.
  macro finished
    {% unless ::Caramel::Tenancy.has_constant?("CENTRAL_SEGMENTS") %}
      {% raise "require \"caramel/tenancy\" needs a tenant block in Caramel::Router.draw\n" +
               "Remediation: name the tenant model and wrap the routes " +
               "that belong to it:\n" +
               "  tenant App::Account, by: :slug do\n" +
               "    get \"/books\", App::Books::Index\n" +
               "  end\n" %}
    {% end %}
  end
end
