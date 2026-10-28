require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  kernel Money, shared_by: [Catalogue, Ordering], means: "the money the shop agrees on" do
    value Cents, Int64, at_least: 0, means: "an amount of money"

    value Millionths, Int64, at_least: 0, means: "a millionth of a unit"
  end

  context Catalogue, shares: Money, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has price : Money::Cents
    end
  end

  context Ordering, shares: Money, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has total : Money::Cents
    end
  end
end

SweetTalk.boot
