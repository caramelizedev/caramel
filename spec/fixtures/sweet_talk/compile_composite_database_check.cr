require "../../../src/caramel"
require "../../../sweettalk/src/sweettalk"

module Shop
  include SweetTalk
  ids Int64

  context Store, means: "the shelves" do
    value Size, database_check: false, means: "a size" do
      part width : Int32
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
