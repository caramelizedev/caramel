require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Pantry, means: "a pantry whose rules PostgreSQL keeps too" do
    aggregate Crate, means: "a crate" do
      has label : String
    end

    projection Sales, means: "tins sold of one tea" do
      key tea : Int64
      has sold : Int32 = 0
      unique :sold
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
