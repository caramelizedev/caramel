require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String?
      event Noted, carries: [note], means: "an order was noted, with its note"

      to forget do
        emit Noted, note: "something else"
      end
    end
  end
end

Shop::Ordering::Order.find(Shop::Ordering::Order::Id.new(1_i64)).forget
SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
