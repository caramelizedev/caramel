require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has stock : Int32

      to ship(tins : Int32) do
        refuse "Only #{stock} tins free.", on: "tins" if tins > stock
        @stock -= tins
      end
    end
  end
end

SweetTalk.boot
