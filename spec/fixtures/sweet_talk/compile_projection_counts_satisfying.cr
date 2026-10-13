require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has tea : Int64
      has tins : Int32
      moves open >> placed

      event Placed, tea : Int64, tins : Int32, means: "a member checked out"
    end

    specification CheckedOut, on: Order, where: {state: :placed}, means: "an order checked out"

    projection Sales, means: "tins sold of one tea" do
      key tea : Int64
      has sold : Int32 = 0

      counts placed_count, satisfying: CheckedOut

      whenever Order::Placed do |placed|
        Sales[placed.tea].sold += placed.tins
      end
    end
  end
end
