# The routes name the tenant model the domain names, as an application's
# config/routes.cr does after its domain.
module TenantShop
  # The bound tenant's slug.
  struct Dashboard < Caramel::Action
    ingress open: true

    contract do
    end

    def handle(contract : Contract)
      Caramel::Response.new(200, tenant.slug)
    end
  end

  Caramel::Router.draw do
    tenant TenantShop::Account, by: :slug do
      get "/", Dashboard
    end
  end
end
