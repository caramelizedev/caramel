require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  kernel Money, shared_by: [Ordering, Fulfilment], means: "the money the shop agrees on" do
    value Cents, Int64, at_least: 0, means: "an amount of money"
  end

  context Catalogue, means: "the teas on our shelves" do
  end

  context Ordering, shares: [Money, Catalogue], means: "choosing teas and checking out" do
  end
end

SweetTalk.boot
