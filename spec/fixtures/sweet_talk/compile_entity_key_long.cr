require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String
      has deliveries : Array(DeliveryOfLooseLeafTea)

      entity DeliveryOfLooseLeafTea, means: "one delivery of this tea" do
        has code : String
        has consignments : Array(ConsignmentOfIt)

        entity ConsignmentOfIt, means: "one consignment" do
          has grams : Int32
        end
      end
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
