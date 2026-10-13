require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Billing, means: "taking payment for orders" do
    border Cards, outside: "the card gateway we charge through" do
      whenever Cards::Charged do |charged|
      end
    end
  end
end

SweetTalk.boot
