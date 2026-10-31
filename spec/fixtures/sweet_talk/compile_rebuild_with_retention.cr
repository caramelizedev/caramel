require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, event_log: 90.days, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has buyer : String

      event Placed, carries: [buyer], means: "a member checked out"
    end

    projection Sales, means: "orders placed by one buyer" do
      key buyer : String
      has placed : Int32 = 0

      whenever Order::Placed do |placed|
        Sales[placed.buyer].placed += 1
      end
    end
  end
end

SweetTalk.boot
SweetTalk.rebuild(Shop::Ordering::Sales)
