require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  requirements :AC1

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String
    end
  end
end

SweetTalk.boot
