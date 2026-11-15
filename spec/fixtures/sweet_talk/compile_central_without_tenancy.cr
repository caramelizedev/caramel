require "../../../src/caramel"
require "../../../sweettalk/src/sweettalk"

module Shop
  include SweetTalk
  ids Int64

  context Catalogue, central: true, means: "the teas every tenant sells" do
    aggregate Tea, means: "one tea" do
      has name : String
    end
  end
end

SweetTalk.boot
