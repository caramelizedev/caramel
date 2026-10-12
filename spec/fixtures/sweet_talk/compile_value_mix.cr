require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    value Tins, Int32, at_least: 0, means: "a count of tins on the shelf"
    value Cents, Int64, at_least: 0, means: "an amount of money"
  end
end

Shop::Catalogue::Tins.new(5) + Shop::Catalogue::Cents.new(900)
SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
