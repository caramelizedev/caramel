require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    value Day, Date, at_least: 1, means: "a calendar day"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
