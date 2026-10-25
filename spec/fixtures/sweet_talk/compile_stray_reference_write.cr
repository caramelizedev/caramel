require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Tea, means: "one tea we sell" do
      has name : String
    end

    aggregate Order, means: "what a member buys at one checkout" do
      has tea : Tea?
      event Chosen, means: "a member chose a tea"

      to choose(tea : Tea) do
        @tea = tea
        emit Chosen
      end
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
