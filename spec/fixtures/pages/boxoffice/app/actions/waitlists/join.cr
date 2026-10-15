module App::Waitlists
  struct Join < App::ApplicationAction
    contract do
      field show : BoxOffice::Seating::Show::Id
      field guest : BoxOffice::Seating::Email
      field seats : BoxOffice::Seating::Seats
    end

    def handle(contract : Contract)
      line = BoxOffice::Waitlist::Line.for_show(contract.show).first?
      return not_found unless line
      line.join(contract.guest, contract.seats)
      redirect_to("/shows/#{contract.show.raw}")
    end
  end
end
