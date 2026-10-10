require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String

      event Restocked, means: "fresh tins reached the shelf"
    end
  end

  context Ordering, follows: Catalogue, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String

      to place do
        emit Catalogue::Tea::Restocked
      end
    end
  end
end

Shop::Ordering::Order.find(Shop::Ordering::Order::Id.new(1_i64)).place
SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
