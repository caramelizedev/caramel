# SweetTalk's calculations (ADR 0062): a typed function whose rules hold on its result, and
# a broken rule a defect that rolls back what it ran in.
require "./support/app"

private alias Carrying = Lots::Carrying

private def cents(amount : Int64) : Carrying::Cents
  Carrying::Cents.new(amount)
end

private def units(*counts : Int32) : Array(Carrying::Units)
  counts.map { |count| Carrying::Units.new(count) }.to_a
end

private def origin(kind : Carrying::Kind) : Carrying::Origin
  Carrying::Origin.new(kind: kind, day: Carrying::Day.new("2026-11-07"))
end

describe "SweetTalk calculations" do
  it "answers what its body computes when its rules hold on the result" do
    shares = Carrying.consume(cents(100), units(1, 1, 1))
    shares.map(&.raw).should eq([33_i64, 33_i64, 34_i64])
  end

  it "raises Broken, not a refusal, when its result breaks a rule" do
    error = expect_raises(SweetTalk::Broken) do
      Carrying.consume_carelessly(cents(100), units(1, 1, 1))
    end
    error.should_not be_a(SweetTalk::Refusal)
    error.calculation.should eq("Carrying.consume_carelessly")
    error.rule.should eq("settling every unit consumes the whole carrying amount")
    error.message.should eq("Carrying.consume_carelessly broke its rule: settling every " \
                            "unit consumes the whole carrying amount")
  end

  it "refuses an input outside its domain before any rule runs" do
    expect_raises(SweetTalk::Refusal, "A lot settles at least one unit.") do
      Carrying.consume(cents(100), units(0, 0))
    end
  end

  it "checks a never line on the result" do
    discount = Carrying::Rate.new("0.25")
    Carrying.worth(cents(200), origin(Carrying::Kind.gifted), discount).raw.should eq(150)
    Carrying.worth(cents(200), origin(Carrying::Kind.bought), discount).raw.should eq(200)
  end

  it "rolls back the transaction a broken rule ends" do
    SweetTalkSpec.committed do
      expect_raises(SweetTalk::Broken) do
        Carrying.record_carelessly(cents(100), units(1, 1, 1))
      end
      SweetTalkSpec.count("carrying_lots").should eq(0)
    end
  end

  it "joins the glossary and SweetTalk.calculations" do
    term = SweetTalk.glossary.find! { |entry| entry.name == "consume" }
    term.kind.should eq("calculation")
    term.context.should eq("Carrying")
    calculation = SweetTalk.calculations.find! { |entry| entry.name == "consume" }
    calculation.context.should eq("Carrying")
    calculation.means.should eq("the carrying amount each settlement consumes, the lot " \
                                "being all of them")
    calculation.arguments.should eq([{"total", "Lots::Carrying::Cents"},
                                     {"settlements", "Array(Lots::Carrying::Units)"}])
    calculation.returns.should eq("Array(Lots::Carrying::Cents)")
    rule = {"always", "settling every unit consumes the whole carrying amount"}
    calculation.rules.should eq([rule])
  end
end
