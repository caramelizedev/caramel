require "../../../src/caramel"
require "../../../sweettalk/src/sweettalk"

module Shop
  include SweetTalk
  ids Int64

  context Catalogue, means: "the teas on our shelves" do
  end

  context Billing, means: "taking payment for orders" do
    border Catalogue, outside: "the shop next door" do
      def self.ping : Nil
      end
    end
  end
end

SweetTalk.boot
