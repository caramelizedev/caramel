require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    value Day, Date, means: "a calendar day"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
Shop::Ordering::Day.new(2026, 3, 1) + Shop::Ordering::Day.new(2026, 3, 2)
