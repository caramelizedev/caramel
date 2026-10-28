require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String

      event Restocked, means: "fresh tins reached the shelf"
    end

    event Renamed, name : String, means: "the shop was given a new name"

    whenever Tea::Restocked do |restocked|
      emit Renamed, name: "restocked"
    end
  end
end

Shop::Catalogue::Tea.find(Shop::Catalogue::Tea::Id.new(1_i64))
SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
