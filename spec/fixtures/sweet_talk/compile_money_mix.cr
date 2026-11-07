require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/sweet_talk/money"

module Shop
  include SweetTalk
  ids Int64

  context Till, means: "the money a shop takes" do
    currencies %w[USD EUR], means: "a currency the till takes"
  end
end

dollars = Shop::Till::Minor(Shop::Till::Currency::USD).new(5_i64)
euros = Shop::Till::Minor(Shop::Till::Currency::EUR).new(5_i64)
dollars + euros

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
