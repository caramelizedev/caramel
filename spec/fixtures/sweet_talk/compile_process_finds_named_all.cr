require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String

      event Placed, means: "a member checked out"
    end

    process Hold, means: "tins held for one order" do
      key order : Int64
      has tins : Int32 = 0

      finds all, order: {tins: :desc}

      whenever Order::Placed, key: placed.order_id.raw do |placed|
        @tins += 1
      end
    end
  end
end
