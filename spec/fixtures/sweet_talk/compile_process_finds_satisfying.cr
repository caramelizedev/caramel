require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String
      moves open >> placed

      event Placed, means: "a member checked out"
    end

    specification CheckedOut, on: Order, where: {state: :placed}, means: "an order checked out"

    process Hold, means: "tins held for one order" do
      key order : Int64
      has tins : Int32 = 0

      finds held, satisfying: CheckedOut

      whenever Order::Placed, key: placed.order_id.raw do |placed|
        @tins += 1
      end
    end
  end
end
