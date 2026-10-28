require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, event_log: true, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has buyer : String
      has lines : Array(Line)

      entity Line, means: "tins of one tea in an order" do
        has tea : String
        has tins : Int32
      end

      event Placed, carries: [lines], means: "a member checked out"
    end

    projection Sales, means: "tins sold of one tea" do
      key tea : String
      has sold : Int32 = 0

      whenever Order::Placed, each: :lines do |placed, line|
        Sales[line.tea].sold += line.tins
      end
    end

    whenever Order::Placed, after: Sales do |placed|
      placed.order_id
    end
  end
end

SweetTalk.boot
