module App::Shows
  struct Show < App::ApplicationAction
    contract do
      field show : App::BoxOffice::Seating::Show::Id
    end

    def handle(contract : Contract)
      show = App::BoxOffice::Seating::Show.find(contract.show)
      page show.title, Views::Shows::Show.new(show, csrf_token)
    end
  end
end
