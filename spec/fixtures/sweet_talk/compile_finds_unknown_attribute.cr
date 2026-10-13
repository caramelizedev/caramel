require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has member : String
      moves open >> placed

      finds of(member : String), where: {membr: member}
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
