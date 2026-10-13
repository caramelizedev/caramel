require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Billing, means: "taking payment for orders" do
    border Cards, outside: true do
      def self.ping : Nil
      end
    end
  end
end

SweetTalk.boot
