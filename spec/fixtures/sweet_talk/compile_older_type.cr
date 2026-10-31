require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has buyer : String

      event Placed, carries: [buyer], older: {buyer: 0}, means: "a member checked out"
    end
  end
end

SweetTalk.boot
