module App::Home
  struct Show < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      page "Welcome", Views::Home::Index.new
    end
  end
end
