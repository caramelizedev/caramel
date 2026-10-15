module App::Sessions
  # The sign-in form, at GET /login.
  struct New < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      page "Sign in", Views::Sessions::New.new(csrf_token, false)
    end
  end
end
