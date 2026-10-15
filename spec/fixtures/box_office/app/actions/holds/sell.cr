module App::Holds
  struct Sell < App::ApplicationAction
    contract do
      field show : App::BoxOffice::Seating::Show::Id
      field hold : Int32, min: 1
    end

    def handle(contract : Contract)
      App::BoxOffice::Seating::Show.find(contract.show).sell(contract.hold)
      redirect_to("/shows/#{contract.show.raw}/holds/#{contract.hold}")
    end
  end
end
