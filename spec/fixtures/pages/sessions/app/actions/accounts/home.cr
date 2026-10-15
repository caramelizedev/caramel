module App::Accounts
  # The account's home page, at /SLUG, for its members.
  struct Home < App::ApplicationAction
    ingress authenticate: :member?

    contract do
    end

    def handle(contract : Contract)
      page tenant.name, Views::Accounts::Home.new(tenant)
    end

    private def member? : Bool
      !current_membership.nil?
    end
  end
end
