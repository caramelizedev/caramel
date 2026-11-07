require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  requirements "AC-1"

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String
    end

    unit annotate(order : Order::Id), changes: [Order], locks: [order], assures: "AC-1",
      means: "annotates an order" do
      never "A note is needed.", assures: "AC-9" { false }
    end
  end
end

SweetTalk.boot
