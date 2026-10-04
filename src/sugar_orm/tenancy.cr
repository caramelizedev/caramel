require "./repo"

class Fiber
  # Whether Caramel::Tenancy.without lifted the scope. The tenant itself,
  # `__sugar_tenant`, is declared with its type by Caramel::Tenancy.declare.
  # Both are set only by SugarORM::Tenancy.bind.
  property? __sugar_untenanted : Bool = false
end

# The tenant a fiber's statements are scoped to (ADR 0025). Only
# `caramel/tenancy` requires this file.
module SugarORM::Tenancy
  # A tenanted statement ran with no tenant bound, outside
  # Caramel::Tenancy.without.
  class Missing < SugarORM::Error
  end

  # Binds *tenant* and *untenanted* to the fiber for the block, restores
  # both afterwards, as Repo.within does, and returns the block's value.
  def self.bind(tenant, untenanted : Bool, &)
    fiber = Fiber.current
    previous_tenant = fiber.__sugar_tenant
    previous_untenanted = fiber.__sugar_untenanted?
    fiber.__sugar_tenant = tenant
    fiber.__sugar_untenanted = untenanted
    begin
      yield
    ensure
      fiber.__sugar_tenant = previous_tenant
      fiber.__sugar_untenanted = previous_untenanted
    end
  end

  # The tenant id *schema*'s statements are scoped to; nil inside
  # Caramel::Tenancy.without.
  def self.scope(schema : String) : Int64?
    fiber = Fiber.current
    if tenant = fiber.__sugar_tenant
      return tenant.__sugar_primary_value
    end
    return if fiber.__sugar_untenanted?
    raise Missing.new(<<-TEXT)
      #{schema} is tenanted, but no tenant is bound.
      Remediation: run it in a tenant route or inside Caramel::Tenancy.with(tenant) { … }; \
      code that must reach every tenant's rows runs inside Caramel::Tenancy.without { … }.
      TEXT
  end

  # The tenant id a new *schema* row belongs to.
  def self.stamp(schema : String) : Int64
    tenant = Fiber.current.__sugar_tenant || raise Missing.new(<<-TEXT)
      A new #{schema} row needs a tenant to belong to, and none is bound.
      Remediation: create it inside Caramel::Tenancy.with(tenant) { … }.
      TEXT
    tenant.__sugar_primary_value
  end
end
