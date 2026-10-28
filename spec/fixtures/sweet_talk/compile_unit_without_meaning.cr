require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String

      to annotate(note : String) do
        @note = note
      end
    end

    unit restock(first : Order::Id, second : Order::Id), changes: [Order],
      locks: [first, second] do
      Order.find(first).annotate "restocked"
      Order.find(second).annotate "restocked"
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
