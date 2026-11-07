require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Billing, means: "what members pay" do
    value Cents, Int64, at_least: 0, means: "an amount in cents"

    event Shared, total : Cents, means: "a total was shared"

    calculation share(total : Cents, parts : Int32), returns: Cents,
      means: "one part of a total" do
      emit Shared, total: total
      total
    end
  end
end

SweetTalk.boot
