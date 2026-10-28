require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Pantry, means: "a pantry whose rules PostgreSQL keeps too" do
    projection Sales, means: "tins sold of one tea" do
      key tea : Int64
      has sold : Int32 = 0, check: {"sold >= 0", "Nothing sells fewer than no tins."}
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
