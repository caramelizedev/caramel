require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String
    end
  end

  context Fulfilment, means: "packing and dispatching parcels" do
    aggregate Parcel, means: "the box we dispatch for one order" do
      has order : Int64

      event Dispatched, means: "a parcel left the shop"
    end

    border Catalogue do
      whenever Parcel::Dispatched do |dispatched|
        dispatched.parcel
      end

      whenever Parcel::Dispatched do |dispatched|
        dispatched.parcel
      end
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
