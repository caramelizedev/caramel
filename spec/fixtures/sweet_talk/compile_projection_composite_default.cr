require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    value Address, means: "where a parcel goes" do
      part street : String
      part city : String
    end

    projection Sales, means: "tins sold of one tea" do
      key tea : Int64
      has deliver_to : Address = Address.new(street: "", city: "")
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
