module App::@@COLLECTION@@
  struct New < App::ApplicationAction
    include Form

    contract do
    end

    def handle(contract : Contract)
      render_form({} of String => String, {} of String => Array(String))
    end
  end
end
