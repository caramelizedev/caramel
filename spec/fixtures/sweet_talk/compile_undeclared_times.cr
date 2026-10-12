require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    value Cents, Int64, at_least: 0, means: "an amount of money"
    value Quantity, Int32, within: 1..10, means: "tins of one tea in one order"
  end
end

Shop::Catalogue::Cents.new(900) * Shop::Catalogue::Quantity.new(2)
SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
