require "../../../src/caramel"
require "../../../src/sugar_orm/decimal"
require "../../../sweettalk/src/sweettalk"
require "../../../sweettalk/src/sweettalk/money"

module Shop
  include SweetTalk
  ids Int64

  context Till, means: "the money a shop takes" do
    currencies %w[USD XAU], exponent: {XAU: 12}, means: "a currency the till takes"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
