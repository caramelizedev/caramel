require "../../../src/caramel/sweet_talk"

module Shop
  include SweetTalk

  context Pricing, means: "how teas are priced" do
    aggregate Tariff, means: "the prices of one tea" do
      has rules : Array(Rule)

      entity Rule, means: "one price band" do
        has slices : Array(Slice)

        entity Slice, means: "one step of a band" do
          has tins : Int32
        end
      end
    end
  end
end

SweetTalk.boot
Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
