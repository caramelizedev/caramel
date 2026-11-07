require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/sweet_talk/money"

module Shop
  include SweetTalk
  ids Int64

  context Till, means: "the money a shop takes" do
    currencies %w[USD EUR], means: "a currency the till takes"
    allocation split, of: Amount, by: Int32, remainder: :nearest, means: "a payout"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
