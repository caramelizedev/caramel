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

    unit annotate_once(request : Int32, order : Order::Id, note : String),
      changes: [Order], locks: [order], once_by: request,
      means: "annotates an order once" do
      Order.find(order).annotate note
    end
  end
end

SweetTalk.boot
