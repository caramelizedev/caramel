require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  kernel Money, shared_by: [Catalogue, Ordering], means: "the money the shop agrees on" do
    value Cents, Int64, at_least: 0, means: "an amount of money"
  end

  context Catalogue, shares: Money, means: "the teas on our shelves" do
  end

  context Ordering, shares: Money, means: "choosing teas and checking out" do
  end

  context Fulfilment, means: "packing and dispatching parcels" do
    border Money do
      def self.zero : Int64
        0_i64
      end
    end
  end
end

SweetTalk.boot
