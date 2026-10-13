require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String
      has lines : Array(Line)

      entity Line, means: "one tea in an order" do
        has tins : Int32
      end

      finds of(lines : Array(Line)), where: {lines: lines}
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
