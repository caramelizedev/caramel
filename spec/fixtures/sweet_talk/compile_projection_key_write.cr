require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Tea, means: "one tea we sell" do
      has name : String
    end

    aggregate Order, means: "what a member buys at one checkout" do
      has tea : Tea
      event Placed, carries: [tea], means: "a member checked out"

      to place do
        emit Placed
      end
    end

    projection Sales, means: "orders placed for one tea" do
      key tea : Tea
      has placed : Int32 = 0

      whenever Order::Placed do |placed|
        row = Sales[placed.tea]
        row.tea = placed.tea
        row.placed += 1
      end
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
