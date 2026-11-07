require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Billing, means: "what members pay" do
    value Cents, Int64, at_least: 0, means: "an amount in cents"

    calculation share(result : Cents, parts : Int32), returns: Cents,
      means: "one part of a total" do
      result
    end
  end
end

SweetTalk.boot
