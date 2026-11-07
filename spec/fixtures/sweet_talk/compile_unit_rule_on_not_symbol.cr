require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String
    end

    unit annotate(order : Order::Id, count : Int32), changes: [Order], locks: [order],
      means: "annotates an order" do
      never "A count is at most nine.", on: "count" { count > 9 }
    end
  end
end

SweetTalk.boot
