require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    value Tins, Int32, at_least: 0, means: "how many tins a shelf holds"
  end

  context Ordering, follows: Catalogue, means: "choosing teas and checking out" do
    value Quantity, Int32, at_least: 1, means: "how many tins an order asks for"
  end
end

SweetTalk.boot
