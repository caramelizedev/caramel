require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String
      event Renamed, means: "a tea was renamed"
    end
  end

  context Billing, means: "taking payment for orders" do
    border Catalogue do
      whenever Catalogue::Tea::Renamed do |renamed|
        HTTP::Client.post("https://api.cards.example/v1/products/#{renamed.tea_id}")
      end
    end
  end
end

SweetTalk.boot
