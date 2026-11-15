require "../../../src/caramel"
require "../../../sweettalk/src/sweettalk"

module Shop
  include SweetTalk
  ids Int64

  context Billing, means: "what members pay" do
    value Cents, Int64, at_least: 0, means: "an amount in cents"
  end
end

require "../../../sweettalk/src/sweettalk/corretto"
