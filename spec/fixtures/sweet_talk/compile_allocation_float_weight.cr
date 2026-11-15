require "../../../src/caramel"
require "../../../src/sugar_orm/decimal"
require "../../../sweettalk/src/sweettalk"
require "../../../sweettalk/src/sweettalk/money"

module Shop
  include SweetTalk
  ids Int64

  context Till, means: "the money a shop takes" do
    currencies %w[USD EUR], means: "a currency the till takes"
    allocation split, of: Amount, by: Float64, remainder: :first, means: "a payout"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
