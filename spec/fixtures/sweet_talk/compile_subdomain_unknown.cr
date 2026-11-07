require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Catalogue, subdomain: :main, means: "the teas on our shelves" do
  end
end

SweetTalk.boot
