require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Till, means: "the money a shop takes" do
    currencies %w[USD EUR], means: "a currency the till takes"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
