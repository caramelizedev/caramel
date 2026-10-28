require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Pricing, means: "what each tea costs" do
    value Rate, Decimal(20, 8), at_least: "0", means: "a yearly rate"
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
