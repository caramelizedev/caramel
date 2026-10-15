require "../spec_helper"

# Builders for the box office's domain specs.
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
end

describe App::BoxOffice do
  it "refuses a hold for more seats than are left" do
    Corretto.session do |_client, _db|
      show = BoxOfficeSpec.show(3)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      expect_raises(SweetTalk::Refusal, "Only 1 seats left for The Tempest.") do
        show.hold(BoxOfficeSpec.email("bo@example.com"), BoxOfficeSpec.seats(2))
      end
      App::BoxOffice::Seating::Show.find(show.id).left.should eq(1)
    end
  end

  it "releases unpaid seats when the ten minutes run out" do
    Corretto.session do |_client, db|
      show = BoxOfficeSpec.show(2)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      Caramel::ColdBrew.drain_queue!(db)
      due = db.query_one("SELECT run_at FROM caramel_jobs WHERE class_name = $1",
        "App::BoxOffice::Seating::Checkout::LapseDeadline", as: Time)
      (due - Time.utc - 10.minutes).abs.should be < 1.minute
      Caramel::ColdBrew.drain_queue!(db, include_scheduled: true)
      App::BoxOffice::Seating::Show.find(show.id).left.should eq(2)
    end
  end

  it "keeps paid seats when the timer runs out after payment" do
    Corretto.session do |_client, db|
      show = BoxOfficeSpec.show(2)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      Caramel::ColdBrew.drain_queue!(db)
      show.sell(1)
      Caramel::ColdBrew.drain_queue!(db, include_scheduled: true)
      sold = App::BoxOffice::Seating::Show.find(show.id)
      sold.tickets.map(&.guest.raw).should eq(["ada@example.com"])
      sold.left.should eq(0)
    end
  end

  it "offers released seats to the first guest in the line they fit" do
    Corretto.session do |_client, db|
      show = BoxOfficeSpec.show(2)
      Caramel::ColdBrew.drain_queue!(db)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      line = App::BoxOffice::Waitlist::Line.for_show(show.id).first
      line.join(BoxOfficeSpec.email("cy@example.com"), BoxOfficeSpec.seats(3))
      line.join(BoxOfficeSpec.email("di@example.com"), BoxOfficeSpec.seats(2))
      show.release(1, "changed plans")
      Caramel::ColdBrew.drain_queue!(db)
      held = App::BoxOffice::Seating::Show.find(show.id).holds
      held.map(&.guest.raw).should eq(["di@example.com"])
      waiting = App::BoxOffice::Waitlist::Line.for_show(show.id).first.guests
      waiting.map(&.email.raw).should eq(["cy@example.com"])
    end
  end
end
