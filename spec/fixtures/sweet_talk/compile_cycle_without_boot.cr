require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, follows: Ordering, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String
    end
  end

  context Ordering, follows: Catalogue, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String

      to rename(member : String) do
        @member = member
      end
    end
  end
end

Shop::Ordering::Order.find(Shop::Ordering::Order::Id.new(1_i64)).rename "ada"
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
