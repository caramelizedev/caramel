require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has stock : Int32
      never "A tea cannot have fewer than no tins.", on: "stock" { stock < 0 }
    end
  end
end

SweetTalk.boot
