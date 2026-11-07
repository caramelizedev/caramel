require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/sweet_talk/money"

module Shop
  include SweetTalk
  ids Int64

  context Till, means: "the money a shop takes" do
    currencies %w[USD EUR], means: "a currency the till takes"
    allocation split, of: Amount, by: Int32, remainder: :first, means: "a payout" do
      always "no part passes half" { result.values.all? { |part| part.raw.to_f <= total.raw } }
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
