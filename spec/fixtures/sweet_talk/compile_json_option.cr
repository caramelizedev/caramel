require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Pricing, means: "what each tea costs" do
    value Evidence, Json, at_least: 0, means: "the figures a price was set from"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
