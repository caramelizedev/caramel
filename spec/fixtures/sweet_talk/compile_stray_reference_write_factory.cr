require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Tea, means: "one tea we sell" do
      has name : String
    end

    aggregate Order, means: "what a member buys at one checkout" do
      has tea : Tea?
      has note : String
      event Opened, means: "a member started an order"

      factory open(tea : Tea, note : String) do
        @tea = tea
        emit Opened
      end
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
