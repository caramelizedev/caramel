require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String

      factory open(member : String) do
      end
    end
  end
end

Shop::Ordering::Order.create(member: "ada")
SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
