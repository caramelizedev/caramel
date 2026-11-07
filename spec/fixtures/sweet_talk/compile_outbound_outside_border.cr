require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Billing, means: "taking payment for orders" do
    aggregate Payment, means: "one charge for one order" do
      has reference : String = ""

      to charge do
        @reference = Caramel::Outbound.post("https://api.cards.example/v1/charges").body
      end
    end
  end
end

SweetTalk.boot
