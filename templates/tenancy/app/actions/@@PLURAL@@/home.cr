module App::@@COLLECTION@@
  # The @@LABEL@@'s home page, at /SLUG, for its members.
  struct Home < App::ApplicationAction
    ingress authenticate: :member?

    contract do
    end

    def handle(contract : Contract)
      page tenant.name, Views::@@COLLECTION@@::Home.new(tenant)
    end
  end
end
