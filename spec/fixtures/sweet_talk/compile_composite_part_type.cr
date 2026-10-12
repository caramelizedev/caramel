require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Fulfilment, means: "packing and dispatching parcels" do
    value Size, means: "how big a parcel is" do
      part weight : Float32
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
