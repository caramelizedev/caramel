module App::Accounts
  struct Create < App::ApplicationAction
    include Form

    # Only a signed-in user creates an account, and becomes its first member.
    ingress authenticate: :signed_in?

    contract do
      field name : String
      field slug : String
    end

    def handle(contract : Contract)
      # signed_in? ran before the contract bound, so current_user is a User.
      user = current_user.as(User)
      changes = App::Account.create(name: contract.name, slug: contract.slug)
      return render_form(contract.values, changes.errors, 422) unless changes.saved?
      App::Membership.create!(user_id: user.id, account_id: changes.record.id)
      self.status = 201
      {record: changes.record}
    end

    def render(result)
      redirect_to("/#{result[:record].slug}")
    end

    private def signed_in? : Bool
      !current_user.nil?
    end
  end
end
