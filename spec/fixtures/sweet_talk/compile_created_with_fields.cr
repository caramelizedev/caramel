require "../../../src/caramel"
require "../../../sweettalk/src/sweettalk"

module Shop
  include SweetTalk
  ids Int64

  context Warehousing, means: "storing goods" do
    aggregate Crate, means: "a crate on the shelf" do
      has reading : Int32

      event Created, label : String, means: "a crate was made"
    end
  end
end

SweetTalk.boot
