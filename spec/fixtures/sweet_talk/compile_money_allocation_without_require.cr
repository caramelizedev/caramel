require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk
  ids Int64

  context Till, means: "the money a shop takes" do
    allocation split, of: Int64, by: Int32, remainder: :first, means: "a payout"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
