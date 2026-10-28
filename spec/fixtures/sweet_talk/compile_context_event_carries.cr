require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String
    end

    event Renamed, carries: [name], means: "the shop was given a new name"
  end
end

SweetTalk.boot
