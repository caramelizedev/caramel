require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  kernel Money, shared_by: [Catalogue, Ordering], means: "the money the shop agrees on" do
    value Cents, Int64, at_least: 0, means: "an amount of money"

    service zero, returns: Cents, means: "no money" do
      Cents.new(0)
    end
  end
end

SweetTalk.boot
