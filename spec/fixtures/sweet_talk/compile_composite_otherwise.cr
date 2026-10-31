require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    value Address, otherwise: "An address needs a street.", means: "where a parcel goes" do
      part street : String
      part city : String
    end

    aggregate Tea, means: "one tea we sell" do
      has name : String
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
