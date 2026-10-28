require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, event_log: true, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has buyer : String

      event Placed, means: "a member checked out"
      event Cancelled, means: "the order was given up"
    end

    projection Sales, means: "orders placed by one buyer" do
      key buyer : String
      has placed : Int32 = 0

      whenever Order::Cancelled do |cancelled|
        Sales[cancelled.order_id.to_s].placed -= 1
      end
    end

    whenever Order::Placed, after: Sales do |placed|
      placed.order_id
    end
  end
end

SweetTalk.boot
