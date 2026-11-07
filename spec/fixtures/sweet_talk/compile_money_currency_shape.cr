require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/sweet_talk/money"

module Shop
  include SweetTalk

  context Till, means: "the money a shop takes" do
    currencies %w[usd], means: "a currency the till takes"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
