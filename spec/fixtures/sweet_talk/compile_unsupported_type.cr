require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has weight : Float32
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
