module App::Health
  class Show < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end
  end
end
