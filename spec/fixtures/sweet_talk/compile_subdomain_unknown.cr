require "../../../src/caramel"
require "../../../sweettalk/src/sweettalk"

module Shop
  include SweetTalk
  ids Int64

  context Catalogue, subdomain: :main, means: "the teas on our shelves" do
  end
end

SweetTalk.boot
