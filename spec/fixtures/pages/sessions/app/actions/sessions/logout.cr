module App::Sessions
  struct Logout < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      current_session.try &.update!(revoked_at: Time.utc)
      sign_out
      true
    end

    def render(result)
      redirect_to "/login"
    end
  end
end
