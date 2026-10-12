require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Store, means: "the shelves" do
    value Tins, Int32, at_least: 0, database_check: true, means: "a count of tins"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
