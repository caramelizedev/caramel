module App::Health
  struct Show < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      Caramel::Response.new(body: "ok")
    end
  end
end
