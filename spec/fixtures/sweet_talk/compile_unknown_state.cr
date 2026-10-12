require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String
      moves open >> placed

      to ship do
        shipped!
      end
    end
  end
end

Shop::Ordering::Order.find(Shop::Ordering::Order::Id.new(1_i64)).ship
SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
