module App::Holds
  struct Create < App::ApplicationAction
    contract do
      field show : BoxOffice::Seating::Show::Id
      field guest : BoxOffice::Seating::Email
      field seats : BoxOffice::Seating::Seats
    end

    def handle(contract : Contract)
      show = BoxOffice::Seating::Show.find(contract.show)
      show.hold(contract.guest, contract.seats)
      redirect_to("/shows/#{show.id.raw}/holds/#{show.issued}")
    end
  end
end
