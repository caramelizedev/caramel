require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  requirements "AC-1"

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String
    end

    unit annotate(order : Order::Id), changes: [Order], locks: [order],
      means: "annotates an order" do
      warn "The note is long.", assures: "AC-1" { false }
    end
  end
end

SweetTalk.boot
