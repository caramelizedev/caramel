require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Ordering, means: "choosing teas and checking out" do
    value Cents, Int64, at_least: 0, means: "an amount in minor units"

    value Money, means: "an amount in one currency" do
      part currency : String
      part cents : Cents
    end

    aggregate Order, means: "what a member buys at one checkout" do
      has total : Money
      has leg : Money?

      finds without_total, where: {total: nil}
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
