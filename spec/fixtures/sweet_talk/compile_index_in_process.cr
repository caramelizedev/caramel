require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Pantry, means: "a pantry whose rules PostgreSQL keeps too" do
    aggregate Crate, means: "a crate" do
      has label : String
    end

    process Tally, means: "how much a crate was counted" do
      key crate : Crate
      has total : Int32 = 0
      index :total
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
