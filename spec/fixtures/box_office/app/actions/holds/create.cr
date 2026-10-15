module App::Holds
  struct Create < App::ApplicationAction
    contract do
      field show : App::BoxOffice::Seating::Show::Id
      field guest : App::BoxOffice::Seating::Email
      field seats : App::BoxOffice::Seating::Seats
    end

    def handle(contract : Contract)
      show = App::BoxOffice::Seating::Show.find(contract.show)
      show.hold(contract.guest, contract.seats)
      redirect_to("/shows/#{show.id.raw}/holds/#{show.issued}")
    end
  end
end
