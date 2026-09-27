module App::Home
  struct Show < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      page "Welcome", view("home/index")
    end
  end
end
