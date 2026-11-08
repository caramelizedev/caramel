# A context across files (ADR 0065): the estate's Picking context is declared in one file
# and continued by `within` in two more, so its event log, its once_by unit and its query
# check must see what the later blocks declare. Picking's header declares two events of its
# own, so a log that read only the header's events would still compile and would raise
# ArgumentError on a basket's; with one header event, `logged` would not compile at all.
require "./support/app"

module EstateSpec
  alias Garden = Estate::Garden
  alias Picking = Estate::Picking

  def self.basket(grams : Int32) : Picking::Basket
    bush = Garden::Bush.create(row: Garden::Row.new(3))
    Picking::Basket.create(bush: bush, weight: Picking::Grams.new(grams))
  end
end

describe "SweetTalk contexts across files" do
  it "logs the events of the header and of a within block, and reads them back" do
    SweetTalkSpec.rolled_back do
      EstateSpec::Picking.start_morning(EstateSpec::Picking::Grams.new(1000))
      basket = EstateSpec.basket(0)
      basket.weigh(EstateSpec::Picking::Grams.new(600))

      EstateSpec::Picking.logged.map(&.class.name).should eq([
        "Estate::Picking::MorningStarted", "Estate::Picking::Calibrated",
        "Estate::Picking::Basket::Created", "Estate::Picking::Basket::Weighed",
      ])
    end
  end

  it "runs a once_by unit a within block declares once per key" do
    SweetTalkSpec.rolled_back do
      basket = EstateSpec.basket(0)
      first = EstateSpec::Picking.weigh_once("w-1", basket.id, 700)
      again = EstateSpec::Picking.weigh_once("w-1", basket.id, 700)

      {first, again}.should eq({700, 700})
      SweetTalkSpec.count("picking_operations").should eq(1)
    end
  end

  it "answers a finds whose specification a later within block declares" do
    SweetTalkSpec.rolled_back do
      EstateSpec.basket(400)
      EstateSpec.basket(600)

      EstateSpec::Picking::Basket.heavy_ones.map(&.weight.raw).should eq([600])
    end
  end
end
