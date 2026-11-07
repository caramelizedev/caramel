require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String

      to annotate(note : String) do
        @note = note
      end
    end

    unit annotate_once(request : String, order : Order::Id, note : String),
      changes: [Order], locks: [order], once_by: request, returns: Order,
      means: "annotates an order once" do
      Order.find(order).annotate note
      Order.find(order)
    end
  end
end

SweetTalk.boot
