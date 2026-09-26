module App::@@COLLECTION@@
  class New < App::ApplicationAction
    include Form

    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      render_form({} of String => String, {} of String => Array(String))
    end
  end
end
