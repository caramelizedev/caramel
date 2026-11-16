require "../../../src/caramel"
require "../../../sweettalk/src/sweettalk"

module Shop
  include SweetTalk
  ids Int64

  context Ordering, means: "choosing teas and checking out" do
    within Ordering do
    end
  end
end

SweetTalk.boot
