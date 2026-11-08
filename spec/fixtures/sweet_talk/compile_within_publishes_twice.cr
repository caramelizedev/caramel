require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Catalogue, means: "the teas on our shelves" do
    value Tins, Int32, means: "a count of tins"

    aggregate Tea, means: "one tea we sell" do
      has tins : Tins
    end

    publishes Tins
  end

  within Catalogue do
    publishes Tea
  end
end

SweetTalk.boot
