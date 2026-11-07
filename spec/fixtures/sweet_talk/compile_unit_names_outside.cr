require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Billing, means: "taking payment for orders" do
    aggregate Payment, means: "one charge for one order" do
      has reference : String = ""

      to settle(reference : String) do
        @reference = reference
      end
    end

    unit charge(payment : Payment::Id), changes: [Payment], locks: [payment],
      means: "charges one payment" do
      found = Payment.find(payment)
      found.settle Cards.charge
    end

    border Cards, outside: "the card gateway we charge through" do
      def self.charge : String
        Caramel::Outbound.post("https://api.cards.example/v1/charges").body
      end
    end
  end
end

SweetTalk.boot
