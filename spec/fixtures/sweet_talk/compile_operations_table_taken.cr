require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String

      to annotate(note : String) do
        @note = note
      end
    end

    unit annotate_once(request : String, order : Order::Id, note : String),
      changes: [Order], locks: [order], once_by: request,
      means: "annotates an order once" do
      Order.find(order).annotate note
    end

    aggregate Operation, means: "an operation the application keeps itself" do
      has name : String
    end
  end
end

SweetTalk.boot
