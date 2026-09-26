module App::Home
  class Show < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      content = Caramel::View.render "#{__DIR__}/../../views/home/index.html.ecr"
      page(Caramel::Page.new("Welcome", content))
    end
  end
end
