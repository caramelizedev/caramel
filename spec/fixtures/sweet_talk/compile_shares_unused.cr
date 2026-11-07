require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  kernel Money, shared_by: [Catalogue, Ordering, Fulfilment],
    means: "the money the shop agrees on" do
    value Cents, Int64, at_least: 0, means: "an amount of money"
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

  context Fulfilment, shares: Money, means: "packing and dispatching parcels" do
    value Parcels, Int32, at_least: 0, means: "how many parcels leave a day"
  end
end

SweetTalk.boot
