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

    process Hold, means: "tins held on the shelf for one placed order" do
      key order : Int64
      has first_tea : Tea?
      moves waiting >> holding

      whenever Order::Placed, key: placed.order_id.raw do |placed|
        @first_tea ||= placed.tea
        holding!
      end
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
