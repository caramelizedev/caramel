module App::Holds
  struct Show < App::ApplicationAction
    contract do
      field show : App::BoxOffice::Seating::Show::Id
      field hold : Int32, min: 1
    end

    def handle(contract : Contract)
      show = App::BoxOffice::Seating::Show.find(contract.show)
      page "Your seats", Views::Holds::Show.new(show, contract.hold, csrf_token)
    end
  end
end
