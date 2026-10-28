require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  kernel Calendar, shared_by: [Catalogue, Ordering], means: "the days the shop counts in" do
    value Day, Date, means: "a calendar day"
  end

  kernel Money, shared_by: [Catalogue, Ordering], shares: Calendar, means: "the money the shop agrees on" do
    value Cents, Int64, at_least: 0, means: "an amount of money"
  end
end

SweetTalk.boot
