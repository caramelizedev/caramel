require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Store, means: "the shelves" do
    value Size, database_check: false, means: "a size" do
      part width : Int32
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
