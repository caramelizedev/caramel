require "../spec_helper"
require "../support/box_office"

describe App::BoxOffice do
  it "refuses a hold for more seats than are left" do
    Corretto.session do |_client, _db|
      show = BoxOfficeSpec.show(3)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      expect_raises(SweetTalk::Refusal, "Only 1 seats left for The Tempest.") do
        show.hold(BoxOfficeSpec.email("bo@example.com"), BoxOfficeSpec.seats(2))
      end
      BoxOfficeSpec.reload(show).left.should eq(1)
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
      BoxOfficeSpec.reload(show).left.should eq(2)
    end
  end

  it "keeps paid seats when the timer runs out after payment" do
    Corretto.session do |_client, db|
      show = BoxOfficeSpec.show(2)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      Caramel::ColdBrew.drain_queue!(db)
      show.sell(1)
      Caramel::ColdBrew.drain_queue!(db, include_scheduled: true)
      sold = BoxOfficeSpec.reload(show)
      sold.tickets.map(&.guest.raw).should eq(["ada@example.com"])
      sold.left.should eq(0)
    end
  end

  it "offers released seats to the first guest in the line they fit" do
    Corretto.session do |_client, db|
      show = BoxOfficeSpec.show(2)
      Caramel::ColdBrew.drain_queue!(db)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      line = BoxOfficeSpec.line(show)
      line.join(BoxOfficeSpec.email("cy@example.com"), BoxOfficeSpec.seats(3))
      line.join(BoxOfficeSpec.email("di@example.com"), BoxOfficeSpec.seats(2))
      show.release(1, "changed plans")
      Caramel::ColdBrew.drain_queue!(db)
      BoxOfficeSpec.reload(show).holds.map(&.guest.raw).should eq(["di@example.com"])
      BoxOfficeSpec.line(show).guests.map(&.email.raw).should eq(["cy@example.com"])
    end
  end
end
