require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Fulfilment, means: "packing and dispatching parcels" do
    aggregate Parcel, means: "the box we dispatch for one order" do
      has teas : Hash(Int64, Int32)
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
