require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/sweet_talk/decimal"

module Shop
  include SweetTalk

  context Pricing, means: "what each tea costs" do
    value Rate, Decimal(20, 8), at_least: "0", means: "a yearly rate"

    projection Rates, means: "the rate of one tea" do
      key tea : Int64
      has rate : Rate = Rate.new("0")
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
