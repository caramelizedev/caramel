require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String
      has lines : Array(Line)

      entity Line, means: "one tea in an order" do
        has tea : String
      end

      the size : Int32 = lines.size
    end

    specification Dispatchable, on: Order, where: {state: :placed},
      means: "an order we may pack and send"
  end
end
