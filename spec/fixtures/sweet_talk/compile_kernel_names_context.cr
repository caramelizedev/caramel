require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String
    end
  end

  kernel Money, shared_by: [Ordering, Fulfilment], means: "the money the shop agrees on" do
    aggregate Voucher, means: "an amount off one tea" do
      has tea : Catalogue::Tea
    end
  end

  context Ordering, shares: Money, means: "choosing teas and checking out" do
  end

  context Fulfilment, shares: Money, means: "packing and dispatching parcels" do
  end
end

SweetTalk.boot
