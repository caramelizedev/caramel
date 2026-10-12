require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, central: true, means: "the teas every tenant sells" do
    aggregate Tea, means: "one tea" do
      has name : String
    end
  end
end

SweetTalk.boot
