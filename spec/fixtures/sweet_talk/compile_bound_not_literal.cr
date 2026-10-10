require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  LEAST = 0

  context Store, means: "the shelves" do
    value Tins, Int32, at_least: LEAST, means: "a count of tins"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
