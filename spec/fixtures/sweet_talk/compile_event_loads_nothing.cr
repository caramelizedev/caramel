require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String

      event Placed, means: "a member checked out"
    end
  end

  context Fulfilment, means: "packing and dispatching parcels" do
    border Ordering do
      whenever Ordering::Order::Placed do |placed|
        placed.order.member
      end
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
