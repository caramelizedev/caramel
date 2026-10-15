# Builders and readers that the box office's specs share.
module BoxOfficeSpec
  extend self

  def show(capacity : Int32) : App::BoxOffice::Seating::Show
    App::BoxOffice::Seating::Show.schedule("The Tempest", Time.utc(2026, 11, 20, 19, 30),
      App::BoxOffice::Seating::Capacity.new(capacity))
  end

  def email(text : String) : App::BoxOffice::Seating::Email
    App::BoxOffice::Seating::Email.new(text)
  end

  def seats(count : Int32) : App::BoxOffice::Seating::Seats
    App::BoxOffice::Seating::Seats.new(count)
  end

  def reload(show : App::BoxOffice::Seating::Show) : App::BoxOffice::Seating::Show
    App::BoxOffice::Seating::Show.find(show.id)
  end

  def line(show : App::BoxOffice::Seating::Show) : App::BoxOffice::Waitlist::Line
    App::BoxOffice::Waitlist::Line.for_show(show.id).first
  end
end
