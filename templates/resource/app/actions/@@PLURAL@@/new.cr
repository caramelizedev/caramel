module App::@@COLLECTION@@
  struct New < App::ApplicationAction
    include Form

    # frappe:only tenant
    ingress authenticate: :member?

    # frappe:end
    contract do
    end

    def handle(contract : Contract)
      render_form({} of String => String, {} of String => Array(String))
    end
  end
end
