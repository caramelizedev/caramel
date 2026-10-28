require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  kernel Money, shared_by: [Catalogue, Ordering] do
    value Cents, Int64, at_least: 0, means: "an amount of money"
  end
end

SweetTalk.boot
