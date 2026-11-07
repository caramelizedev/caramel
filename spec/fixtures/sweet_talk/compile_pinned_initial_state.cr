require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Ordering, means: "choosing teas and checking out" do
    aggregate Terms, means: "what one order is charged" do
      has rate : Int64
    end

    aggregate Order, means: "what a member buys at one checkout" do
      has terms : Terms, pinned_at: :open
      moves open >> placed
    end
  end
end

SweetTalk.boot
