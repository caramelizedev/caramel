require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    value Tins, Int32, at_least: 0, otherwise: 5, means: "a count of tins on the shelf"

    aggregate Tea, means: "one tea we sell" do
      has name : String
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
