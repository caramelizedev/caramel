require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Catalogue, means: "the teas on our shelves" do
    aggregate Tea, means: "one tea we sell" do
      has name : String

      to rename(name : String) do
        @name = name
      end
    end
  end

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String

      to annotate(note : String) do
        @note = note
      end
    end

    unit restock(order : Order::Id, tea : Catalogue::Tea::Id, name : String),
      changes: [Order, Catalogue::Tea], locks: [order, tea],
      means: "annotates an order and renames a tea together" do
      Order.find(order).annotate name
      Catalogue::Tea.find(tea).rename name
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
