# SweetTalk's money module (ADR 0063): amounts in a currency's minor units, their currency
# a type or data, stored with a currency column under a CHECK; text read exactly or
# rounded on purpose; dated rates kept as exact fractions, converting as their quote
# rounds; an event, a projection, a finder and a specification over amounts; and
# allocations whose rules hold on drawn cases and catch a seeded off-by-one.
require "./support/app"
require "../../src/caramel/corretto/property"

module MoneySpec
  alias Money = Books::Cash
  alias Ledger = Books::Payments
  alias USD = Money::Minor(Money::Currency::USD)
  alias EUR = Money::Minor(Money::Currency::EUR)
  alias JPY = Money::Minor(Money::Currency::JPY)

  # Weights by key, each written as a decimal percent.
  def self.weights(pairs : Hash(Int64, String)) : Hash(Int64, Ledger::Weight)
    pairs.transform_values { |text| Ledger::Weight.new(text) }
  end

  # The parts of an allocation as minor units, in key order.
  def self.units(parts : Hash(Int64, V)) : Hash(Int64, Int64) forall V
    parts.transform_values(&.raw)
  end

  def self.amount(text : String, code : String) : Money::Amount
    Money::Amounts.parse(text, Money::Currency.new(code))
  end

  def self.day : Money::RateDay
    Money::RateDay.new("2026-11-06")
  end

  def self.rate(text : String, from : String, to : String,
                source : String = "ECB") : Money::Rate
    Money::Rate.parse(text, from: Money::Currency.new(from), to: Money::Currency.new(to),
      day: day, source: source)
  end

  def self.entry(text : String, code : String) : Ledger::Entry
    Ledger::Entry.create(original: amount(text, code))
  end

  # Runs *sql* in its own savepoint and returns the check it broke.
  def self.broken(sql : String, *args) : String?
    SugarORM::Repo.transaction { SugarORM.sql_exec(sql, *args) }
    nil
  rescue error : SugarORM::CheckViolation
    error.constraint
  end
end

describe "SweetTalk's currencies" do
  it "takes each code's minor units from ISO 4217, or from exponent:" do
    MoneySpec::Money::Currency.all.map(&.exponent).should eq([2, 2, 2, 0, 3, 2, 4])
    MoneySpec::Money::Currency::JPY::EXPONENT.should eq(0)
    MoneySpec::Money::Currency.usd.usd?.should be_true
    MoneySpec::Money::Currency.new("TRY").exponent.should eq(2)
    listed = "Currency must be one of USD, EUR, UZS, JPY, BHD, TRY, XAU"
    expect_raises(SweetTalk::Refusal, listed) do
      MoneySpec::Money::Currency.new("GBP")
    end
  end
end

describe "SweetTalk's amounts" do
  it "reads text in the currency's units, and refuses more decimals than it keeps" do
    MoneySpec::USD.parse("12.3").raw.should eq(1230)
    MoneySpec::USD.parse("-0.05").to_s.should eq("-0.05 USD")
    MoneySpec.amount("1200", "JPY").to_s.should eq("1200 JPY")
    MoneySpec.amount("1.005", "BHD").raw.should eq(1005)
    MoneySpec.amount("0.0001", "XAU").text.should eq("0.0001")
    expect_raises(SweetTalk::Refusal, "USD keeps 2 decimals, not 12.345") do
      MoneySpec::USD.parse("12.345")
    end
    expect_raises(SweetTalk::Refusal, "JPY keeps 0 decimals, not 1.5") do
      MoneySpec.amount("1.5", "JPY")
    end
    expect_raises(SweetTalk::Refusal, "USD must be a decimal written with digits and a point") do
      MoneySpec::USD.parse("1e3")
    end
  end

  it "rounds text to the currency's units only when asked, as the rounding says" do
    MoneySpec::USD.round("12.345", rounding: :half_up).raw.should eq(1235)
    MoneySpec::USD.round("12.345", rounding: :half_even).raw.should eq(1234)
    MoneySpec::USD.round("12.355", rounding: :half_even).raw.should eq(1236)
    MoneySpec::USD.round("-12.345", rounding: :half_up).raw.should eq(-1235)
    MoneySpec::USD.round("12.341", rounding: :up).raw.should eq(1235)
    MoneySpec::USD.round("-12.349", rounding: :down).raw.should eq(-1234)
    rounded = MoneySpec::Money::Amounts.round("2.5", MoneySpec::Money::Currency.jpy,
      rounding: :half_even)
    rounded.raw.should eq(2)
  end

  it "adds its own currency, and combines two whose currency is data only when they agree" do
    (MoneySpec::USD.parse("1.10") + MoneySpec::USD.parse("2.20")).raw.should eq(330)
    (-MoneySpec::USD.parse("1.10") * 3).raw.should eq(-330)
    (MoneySpec::USD.parse("1") < MoneySpec::USD.parse("2")).should be_true
    first = MoneySpec.amount("1.10", "EUR")
    sum = MoneySpec::Money.same(first, MoneySpec.amount("2.20", "EUR")) { |x, y| x + y }
    sum.should eq(MoneySpec::EUR.new(330))
    expect_raises(SweetTalk::Refusal, "An amount in EUR and one in USD cannot be combined") do
      MoneySpec::Money.same(first, MoneySpec.amount("2.20", "USD")) { |x, y| x + y }
    end
    totals = MoneySpec::Money.by_currency(
      [first, MoneySpec.amount("5", "JPY"), MoneySpec.amount("-1.10", "EUR")])
    totals.should eq({MoneySpec::Money::Currency.eur => MoneySpec::EUR.new(0),
                      MoneySpec::Money::Currency.jpy => MoneySpec.amount("5", "JPY")})
  end

  it "is stored as its currency and its minor units, with the currencies as a CHECK" do
    SweetTalkSpec.rolled_back do
      entry = MoneySpec.entry("12.30", "EUR")
      stored = SugarORM.sql("SELECT original_currency, original FROM payments_entries",
        as: {original_currency: String, original: Int64}).first
      stored.should eq({original_currency: "EUR", original: 1230})
      loaded = MoneySpec::Ledger::Entry.find(entry.id)
      loaded.original.should eq(MoneySpec::EUR.new(1230))
      loaded.reported.should be_nil
      loaded.fee.should be_nil
      check = MoneySpec.broken(
        "UPDATE payments_entries SET original_currency = 'GBP' WHERE id = $1", entry.id.raw)
      check.to_s.should start_with("check_payments_entries_original_currency_one_of_")
      check = MoneySpec.broken(
        "UPDATE payments_entries SET reported = 5 WHERE id = $1", entry.id.raw)
      check.should eq("check_payments_entries_reported_all_or_none")
    end
  end

  it "stores an amount whose currency is a type, and amounts in an entity" do
    SweetTalkSpec.rolled_back do
      entry = MoneySpec.entry("10", "USD")
      entry.charge(MoneySpec::USD.parse("0.25"))
      entry.split([MoneySpec.amount("4", "USD"), MoneySpec.amount("600", "JPY")])
      loaded = MoneySpec::Ledger::Entry.find(entry.id)
      loaded.fee.should eq(MoneySpec::USD.new(25))
      loaded.lines.map(&.share).should eq(
        [MoneySpec.amount("4", "USD"), MoneySpec.amount("600", "JPY")])
      SugarORM.sql_exec("UPDATE payments_entries SET fee_currency = 'EUR' WHERE id = $1",
        entry.id.raw)
      expect_raises(SweetTalk::Refusal, "EUR is not USD") do
        MoneySpec::Ledger::Entry.find(entry.id)
      end
    end
  end

  it "finds an amount by its currency and units, and an unset one by nil" do
    SweetTalkSpec.rolled_back do
      euros = MoneySpec.entry("5", "EUR")
      MoneySpec.entry("5", "USD")
      found = MoneySpec::Ledger::Entry.of_amount(MoneySpec.amount("5.00", "EUR"))
      found.map(&.id).should eq([euros.id])
      MoneySpec::Ledger::Entry.unreported.size.should eq(2)
      every = MoneySpec::Ledger::Entry.all(satisfying: MoneySpec::Ledger::Unreported)
      every.size.should eq(2)
    end
  end

  it "needs no migration once its tables exist" do
    declared = SugarORM::Catalog.declared
    snapshot = SugarORM::Introspection.read(SweetTalkSpec.owner)
    plan = SugarORM::Differ.diff(declared, snapshot)
    (plan.transactional + plan.online).should be_empty
  end
end

describe "SweetTalk's quotes" do
  it "keeps a rate as an exact fraction, read the other way and through another" do
    rate = MoneySpec.rate("1.0851", "EUR", "USD")
    rate.fraction.should eq(BigRational.new(10851, 10000))
    rate.inverse.fraction.should eq(BigRational.new(10000, 10851))
    som = MoneySpec.rate("12650.5", "USD", "UZS", "CBU")
    cross = rate.through(som)
    cross.fraction.should eq(BigRational.new(10851, 10000) * BigRational.new(253010, 20))
    cross.from.should eq(MoneySpec::Money::Currency.eur)
    cross.to.should eq(MoneySpec::Money::Currency.uzs)
    cross.source.should eq("ECB, CBU")
    expect_raises(SweetTalk::Refusal, "A EUR to USD rate does not lead through one from EUR") do
      rate.through(rate)
    end
    refused = "A Rate converts between two currencies at a fraction above zero"
    expect_raises(SweetTalk::Refusal, refused) do
      MoneySpec.rate("1", "USD", "USD")
    end
    expect_raises(SweetTalk::Refusal, refused) do
      MoneySpec.rate("0", "EUR", "USD")
    end
  end

  it "converts an amount into the rate's currency, rounded as its quote declares" do
    rate = MoneySpec.rate("1.0851", "EUR", "USD")
    MoneySpec::EUR.parse("100").convert(rate).should eq(MoneySpec::USD.new(10851))
    # 0.50 EUR is 0.54255 USD: half up gives 0.54.
    MoneySpec::EUR.parse("0.50").convert(rate).should eq(MoneySpec::USD.new(54))
    MoneySpec::EUR.parse("-0.50").convert(rate).should eq(MoneySpec::USD.new(-54))
    # 1 USD at 155.5 JPY is 155.5 yen, which half up makes 156.
    yen = MoneySpec.rate("155.5", "USD", "JPY")
    MoneySpec::USD.parse("1").convert(yen).should eq(MoneySpec.amount("156", "JPY"))
    MoneySpec.amount("156", "JPY").convert(yen.inverse).should eq(MoneySpec::USD.new(100))
    expect_raises(SweetTalk::Refusal, "This Rate converts EUR, not USD") do
      MoneySpec::USD.parse("1").convert(rate)
    end
  end

  it "stores a rate part by part, and an event carries amounts to a projection" do
    SweetTalkSpec.rolled_back do |connection|
      entry = MoneySpec.entry("100", "EUR")
      rate = MoneySpec.rate("1.0851", "EUR", "USD")
      reported = SweetTalk.emitted(MoneySpec::Ledger::Entry::Reported) do
        entry.report(rate)
      end.first
      reported.reported.should eq(MoneySpec::USD.new(10851))
      loaded = MoneySpec::Ledger::Entry.find(entry.id)
      loaded.rate.should eq(rate)
      loaded.reported.should eq(MoneySpec.amount("108.51", "USD"))
      Caramel::ColdBrew.drain_queue(connection)
      row = MoneySpec::Ledger::Totals.all.first
      row.reported.should eq(MoneySpec.amount("108.51", "USD"))
      row.conversions.should eq(1)
    end
  end
end

describe "SweetTalk's allocations" do
  it "splits exactly, gives the units left to the largest fractions, and breaks ties by key" do
    thirds = MoneySpec.weights({3_i64 => "1", 1_i64 => "1", 2_i64 => "1"})
    parts = MoneySpec::Ledger.split(MoneySpec.amount("100", "USD"), thirds)
    parts.keys.should eq([1, 2, 3])
    MoneySpec.units(parts).should eq({1 => 3334, 2 => 3333, 3 => 3333})
    parts.values.all?(MoneySpec::USD).should be_true
    owners = MoneySpec.weights({1_i64 => "50.5", 2_i64 => "49.5", 3_i64 => "0"})
    MoneySpec.units(MoneySpec::Ledger.split(MoneySpec.amount("0.07", "EUR"), owners))
      .should eq({1 => 4, 2 => 3, 3 => 0})
    MoneySpec.units(MoneySpec::Ledger.split(MoneySpec.amount("-0.07", "EUR"), owners))
      .should eq({1 => -4, 2 => -3, 3 => 0})
  end

  it "gives the units left to the first, the last or a named key, as remainder: says" do
    owners = MoneySpec.weights({1_i64 => "1", 2_i64 => "1", 3_i64 => "1", 4_i64 => "0"})
    total = MoneySpec.amount("1.00", "USD")
    MoneySpec.units(MoneySpec::Ledger.front(total, owners))
      .should eq({1 => 34, 2 => 33, 3 => 33, 4 => 0})
    MoneySpec.units(MoneySpec::Ledger.sweep(MoneySpec.amount("1.01", "USD"), owners, 2_i64))
      .should eq({1 => 33, 2 => 35, 3 => 33, 4 => 0})
    shares = {1_i64 => 1, 2_i64 => 1, 3_i64 => 1}
    MoneySpec.units(MoneySpec::Ledger.back(MoneySpec::JPY.new(1000), shares))
      .should eq({1 => 333, 2 => 333, 3 => 334})
    expect_raises(SweetTalk::Refusal,
      "The remainder of an allocation goes to a key with a weight above zero, not 4") do
      MoneySpec::Ledger.sweep(MoneySpec.amount("1.01", "USD"), owners, 4_i64)
    end
  end

  it "refuses a weight below zero, or weights that add up to nothing" do
    expect_raises(SweetTalk::Refusal, "An allocation takes no weight below zero") do
      MoneySpec::Ledger.back(MoneySpec::JPY.new(10), {1_i64 => 2, 2_i64 => -1})
    end
    expect_raises(SweetTalk::Refusal, "An allocation needs a weight above zero") do
      MoneySpec::Ledger.split(MoneySpec.amount("1", "USD"), MoneySpec.weights({1_i64 => "0"}))
    end
  end

  it "holds its rules on 200 drawn cases of each remainder" do
    Corretto.property(Books::Payments.split).held.should be > 0
    Corretto.property(Books::Payments.front).held.should be > 0
    Corretto.property(Books::Payments.back).held.should be > 0
    Corretto.property(Books::Payments.sweep).held.should be > 0
  end

  it "catches a split that gives out one unit too few within 200 drawn cases" do
    failure = expect_raises(Spec::AssertionFailed, "broke its rule") do
      Corretto.property(Books::Payments.short)
    end
    failure.message.to_s.should contain(
      "Payments.short broke its rule: the parts add up to the total, in its currency")
    failure.message.to_s.should contain("rerun with CORRETTO_SEED=")
  end
end
