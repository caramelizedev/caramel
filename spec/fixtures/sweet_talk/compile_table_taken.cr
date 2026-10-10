require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Store, means: "the shelves" do
    aggregate Tea, means: "a tea" do
      has name : String
      has tins : Array(Tin)

      entity Tin, means: "one tin of a tea" do
        has grams : Int32
      end
    end

    aggregate TeaTin, means: "a tin of tea sold alone" do
      has grams : Int32
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
