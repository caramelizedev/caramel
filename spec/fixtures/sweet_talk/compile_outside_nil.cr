require "../../../src/caramel"
require "../../../sweettalk/src/sweettalk"

module Shop
  include SweetTalk
  ids Int64

  context Billing, means: "taking payment for orders" do
    border Cards, outside: nil do
      def self.ping : Nil
      end
    end
  end
end

SweetTalk.boot
