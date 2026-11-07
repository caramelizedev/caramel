require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Billing, means: "what members pay" do
    value Cents, Int64, at_least: 0, means: "an amount in cents"

    aggregate Invoice, means: "what one member owes" do
      has total : Cents
    end

    calculation share(invoice : Invoice, parts : Int32), returns: Cents,
      means: "one part of an invoice" do
      invoice.total
    end
  end
end

SweetTalk.boot
