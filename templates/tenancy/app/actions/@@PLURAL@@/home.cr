module App::@@COLLECTION@@
  # The @@LABEL@@'s home page, at /SLUG.
  struct Home < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      page tenant.name, Views::@@COLLECTION@@::Home.new(tenant)
    end
  end
end
