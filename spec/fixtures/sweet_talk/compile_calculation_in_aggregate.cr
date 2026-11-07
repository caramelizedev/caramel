require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Billing, means: "what members pay" do
    value Cents, Int64, at_least: 0, means: "an amount in cents"

    aggregate Invoice, means: "what one member owes" do
      has total : Cents

      calculation share(parts : Int32), returns: Cents, means: "one part of the total" do
        total
      end
    end
  end
end

SweetTalk.boot
