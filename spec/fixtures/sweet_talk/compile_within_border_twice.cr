require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Billing, means: "taking payment for orders" do
    border Cards, outside: "the card gateway we charge through" do
      def self.ping : Nil
      end
    end
  end

  within Billing do
    border Cards, outside: "the card gateway we charge through" do
      def self.ping : Nil
      end
    end
  end
end

SweetTalk.boot
