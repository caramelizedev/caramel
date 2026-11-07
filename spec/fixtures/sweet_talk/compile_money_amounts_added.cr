require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/sweet_talk/money"

module Shop
  include SweetTalk
  ids Int64

  context Till, means: "the money a shop takes" do
    currencies %w[USD EUR], means: "a currency the till takes"
  end
end

first = Shop::Till::Amounts.parse("5", Shop::Till::Currency.usd)
second = Shop::Till::Amounts.parse("5", Shop::Till::Currency.eur)
first + second

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
