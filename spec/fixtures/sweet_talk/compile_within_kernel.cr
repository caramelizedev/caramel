require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  kernel Money, shared_by: [Ordering, Billing], means: "amounts both contexts charge" do
    value Cents, Int64, means: "an amount in cents"
  end

  within Money do
    value Pence, Int64, means: "an amount in pence"
  end
end

SweetTalk.boot
