require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Pantry, means: "a pantry whose rules PostgreSQL keeps too" do
    aggregate Crate, means: "a crate" do
      has label : String, unique: true
      unique :label, otherwise: "That label is taken."
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
