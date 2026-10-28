# SweetTalk's decimal and JSON values (ADR 0047): `value Rate, Decimal(20, 8)` is a
# BigDecimal kept exact in a numeric column with its bounds as a CHECK, ranged, sorted,
# counted and read by a specification; `value Evidence, Json(Snapshot)` and `value Note,
# Json` are documents kept in jsonb columns, optional in an aggregate and in a projection;
# and an event carries a rate as text and a document as JSON.
require "./support/app"

module DecimalAndJsonValuesSpec
  alias Credit = Treasury::Credit

  def self.rate(text : String) : Credit::Rate
    Credit::Rate.new(text)
  end

  def self.evidence(source : String, base_points : Int32) : Credit::Evidence
    Credit::Evidence.new(Treasury::Snapshot.new(source, base_points))
  end

  def self.loan(rate : String = "0.05", borrower : String = "Ada") : Credit::Loan
    Credit::Loan.create(borrower: borrower, rate: rate(rate))
  end

  # One loan for each rate, made in that order.
  def self.loans(*rates : String) : Array(Credit::Loan)
    rates.map { |text| loan(text) }.to_a
  end

  def self.ids(loans : Array(Credit::Loan)) : Array(Credit::Loan::Id)
    loans.map(&.id)
  end

  # The column type PostgreSQL holds for *table*'s *column*, and whether it is nullable.
  def self.column(table : String, column : String) : {String, Bool}
    query = <<-SQL
      SELECT format_type(a.atttypid, a.atttypmod) AS held, NOT a.attnotnull AS nullable
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relname = '#{table}' AND a.attname = '#{column}'
      SQL
    row = SugarORM.sql(query, as: {held: String, nullable: Bool}).first
    {row[:held], row[:nullable]}
  end

  # Runs *sql* in its own savepoint and returns the check it broke.
  def self.broken(sql : String, *args) : String?
    SugarORM::Repo.transaction { SugarORM.sql_exec(sql, *args) }
    nil
  rescue error : SugarORM::CheckViolation
    error.constraint
  end

  # Checks that *rule* picks the loans at *positions* of *loans*, asked of PostgreSQL by
  # `all(satisfying:)` and of each aggregate in *everything* by `satisfied_by?`.
  def self.agree(rule : T.class, everything : Array(Credit::Loan),
                 loans : Array(Credit::Loan), positions : Array(Int32)) : Nil forall T
    expected = positions.map { |position| loans[position].id.raw }.sort!
    Credit::Loan.all(satisfying: rule).map(&.id.raw).sort!.should eq(expected)
    everything.select { |loan| rule.satisfied_by?(loan) }.map(&.id.raw).sort!.should eq(expected)
  end

  def self.jobs_fields : Array(String)
    SugarORM.sql("SELECT payload->>'fields' AS fields FROM caramel_jobs ORDER BY id",
      as: {fields: String}).map(&.[:fields])
  end
end

describe "SweetTalk's decimal values" do
  it "reads digits with a point, and refuses other text, a bound crossed or a decimal past S" do
    DecimalAndJsonValuesSpec.rate("0.05").to_s.should eq("0.05")
    DecimalAndJsonValuesSpec.rate("1").to_s.should eq("1")
    DecimalAndJsonValuesSpec.rate("0.50").to_s.should eq("0.5")
    ["1e-2", "0,5", " 0.5", "0.5 ", ".5", "5.", "+0.5", "0x1", "", "five"].each do |text|
      expect_raises(SweetTalk::Refusal,
        "Rate must be a decimal written with digits and a point, as in 12.50") do
        Treasury::Credit::Rate.new(text)
      end
    end
    expect_raises(SweetTalk::Refusal, "Rate must be at most 1") do
      DecimalAndJsonValuesSpec.rate("1.5")
    end
    expect_raises(SweetTalk::Refusal, "Rate must be at least 0") do
      DecimalAndJsonValuesSpec.rate("-0.1")
    end
    expect_raises(SweetTalk::Refusal,
      "Rate keeps 8 decimals and 12 digits before the point, not 0.123456789") do
      Treasury::Credit::Rate.new("0.123456789")
    end
    expect_raises(SweetTalk::Refusal,
      "Spread keeps 4 decimals and 2 digits before the point, not 100") do
      Treasury::Credit::Spread.new(100)
    end
    Treasury::Credit::Spread.new("-0.5").to_s.should eq("-0.5")
    expect_raises(SweetTalk::Refusal, "Spread must be at least -0.5") do
      Treasury::Credit::Spread.new("-0.5001")
    end
  end

  it "is a BigDecimal underneath, with a codec for numeric(20,8)" do
    rate = DecimalAndJsonValuesSpec.rate("0.05")
    rate.raw.should eq(BigDecimal.new("0.05"))
    rate.raw.should be_a(BigDecimal)
    Treasury::Credit::Rate.new(BigDecimal.new("0.05")).should eq(rate)
    Treasury::Credit::Rate::SWEETTALK_WRAPS.should eq("::BigDecimal")
    Treasury::Credit::Rate::SWEETTALK_CODEC.should eq("::SugarORM::DecimalCodec(20, 8)")
    Treasury::Credit::Rate::SWEETTALK_CHECK
      .should eq({"column", "between_0_and_1", "BETWEEN 0 AND 1"})
    Treasury::Credit::Spread::SWEETTALK_CHECK.should eq({"column", "from_minus0_5", ">= -0.5"})
    Treasury::Credit::Rate.zero.to_s.should eq("0")
  end

  it "compares and sorts exactly, whatever the scale written, and adds, subtracts and scales" do
    rates = %w[0.5 0.25 1 0.50 0.125].map { |text| DecimalAndJsonValuesSpec.rate(text) }
    rates.sort.map(&.to_s).should eq(%w[0.125 0.25 0.5 0.5 1])
    (rates[0] == rates[3]).should be_true
    rates.to_set.size.should eq(4)
    tenth = DecimalAndJsonValuesSpec.rate("0.1")
    (tenth + DecimalAndJsonValuesSpec.rate("0.2")).to_s.should eq("0.3")
    (DecimalAndJsonValuesSpec.rate("0.3") - tenth).to_s.should eq("0.2")
    (DecimalAndJsonValuesSpec.rate("0.25") * 3).to_s.should eq("0.75")
    expect_raises(SweetTalk::Refusal, "Rate must be at most 1") do
      DecimalAndJsonValuesSpec.rate("0.5") * 3
    end
  end

  it "is kept exact in a numeric column, with its bounds as a CHECK PostgreSQL keeps" do
    SweetTalkSpec.rolled_back do
      loan = DecimalAndJsonValuesSpec.loan("0.12345678")
      DecimalAndJsonValuesSpec.column("credit_loans", "rate").should eq({"numeric(20,8)", false})
      DecimalAndJsonValuesSpec.column("credit_loans", "spread").should eq({"numeric(6,4)", true})
      stored = SugarORM.sql("SELECT rate::text AS rate FROM credit_loans", as: {rate: String})
      stored.first[:rate].should eq("0.12345678")
      Treasury::Credit::Loan.find(loan.id).rate
        .should eq(DecimalAndJsonValuesSpec.rate("0.12345678"))
      check = DecimalAndJsonValuesSpec.broken(
        "UPDATE credit_loans SET rate = 1.5 WHERE id = $1", loan.id.raw)
      check.should eq("check_credit_loans_rate_between_0_and_1")
      check = DecimalAndJsonValuesSpec.broken(
        "UPDATE credit_loans SET spread = -0.6 WHERE id = $1", loan.id.raw)
      check.should eq("check_credit_loans_spread_from_minus0_5")
    end
  end

  it "stores an optional decimal as null, then as given" do
    SweetTalkSpec.rolled_back do
      loan = DecimalAndJsonValuesSpec.loan
      Treasury::Credit::Loan.find(loan.id).spread.should be_nil
      loan.widen(Treasury::Credit::Spread.new("0.0125"))
      Treasury::Credit::Loan.find(loan.id).spread.should eq(Treasury::Credit::Spread.new("0.0125"))
      loan.widen(nil)
      Treasury::Credit::Loan.find(loan.id).spread.should be_nil
    end
  end

  it "finds a range of rates, those from a rate, one rate exactly, sorts by rate and counts" do
    SweetTalkSpec.rolled_back do
      loans = DecimalAndJsonValuesSpec.loans("0.1", "0.05", "0.25", "0.05000000", "0")
      between = Treasury::Credit::Loan.priced_between(DecimalAndJsonValuesSpec.rate("0.05"),
        DecimalAndJsonValuesSpec.rate("0.1"))
      DecimalAndJsonValuesSpec.ids(between)
        .should eq(DecimalAndJsonValuesSpec.ids([loans[0], loans[1], loans[3]]))
      from = Treasury::Credit::Loan.priced_from(DecimalAndJsonValuesSpec.rate("0.1"))
      DecimalAndJsonValuesSpec.ids(from)
        .should eq(DecimalAndJsonValuesSpec.ids([loans[0], loans[2]]))
      exact = Treasury::Credit::Loan.priced_at(DecimalAndJsonValuesSpec.rate("0.05"))
      DecimalAndJsonValuesSpec.ids(exact)
        .should eq(DecimalAndJsonValuesSpec.ids([loans[1], loans[3]]))
      DecimalAndJsonValuesSpec.ids(Treasury::Credit::Loan.cheapest_first)
        .should eq(DecimalAndJsonValuesSpec.ids([loans[4], loans[1], loans[3], loans[0], loans[2]]))
      Treasury::Credit::Loan.priced_from_count(DecimalAndJsonValuesSpec.rate("0.05"))
        .should eq(4)
    end
  end

  it "reads a rate in a specification the same in Crystal and PostgreSQL" do
    SweetTalkSpec.rolled_back do
      loans = DecimalAndJsonValuesSpec.loans("0.05", "0.0500001", "0", "0.25")
      everything = Treasury::Credit::Loan.all
      DecimalAndJsonValuesSpec.agree(Treasury::Credit::Cheap, everything, loans, [0, 2])
      DecimalAndJsonValuesSpec.agree(Treasury::Credit::Free, everything, loans, [2])
    end
  end

  it "needs no migration once its tables exist" do
    declared = SugarORM::Catalog.declared
    snapshot = SugarORM::Introspection.read(SweetTalkSpec.owner)
    plan = SugarORM::Differ.diff(declared, snapshot)
    (plan.transactional + plan.online).should be_empty
    plan.halts.should be_empty
  end
end

private struct Quote
  include JSON::Serializable

  getter rate : Treasury::Credit::Rate
  getter spread : Treasury::Credit::Spread?
  getter evidence : Treasury::Credit::Evidence?
end

describe "SweetTalk's decimal values as JSON" do
  it "writes a rate as its text and reads it back, refusing a number or other text" do
    rate = DecimalAndJsonValuesSpec.rate("0.05")
    rate.to_json.should eq(%("0.05"))
    [rate].to_json.should eq(%(["0.05"]))
    quote = Quote.from_json(%({"rate":"0.05","spread":null}))
    quote.rate.should eq(rate)
    quote.spread.should be_nil
    quote.evidence.should be_nil
    quote.to_json.should eq(%({"rate":"0.05"}))
    expect_raises(JSON::ParseException, "Rate must be a decimal written with digits") do
      Quote.from_json(%({"rate":"1e-2"}))
    end
    expect_raises(JSON::ParseException) { Quote.from_json(%({"rate":0.05})) }
    expect_raises(SweetTalk::Refusal, "Rate must be at most 1") do
      Quote.from_json(%({"rate":"2"}))
    end
  end
end

describe "SweetTalk's JSON values" do
  it "wraps a JSON::Serializable type or any document, and is a jsonb column" do
    evidence = DecimalAndJsonValuesSpec.evidence("ECB", 500)
    evidence.raw.should be_a(Treasury::Snapshot)
    evidence.raw.source.should eq("ECB")
    evidence.to_json.should eq(%({"source":"ECB","base_points":500}))
    evidence.to_s.should eq(%({"source":"ECB","base_points":500}))
    Treasury::Credit::Evidence.parse(%({"source":"ECB","base_points":500}))
      .should eq(evidence)
    Treasury::Credit::Evidence::SWEETTALK_WRAPS.should eq("::Treasury::Snapshot")
    Treasury::Credit::Evidence::SWEETTALK_CODEC
      .should eq("::SugarORM::JSONB(::Treasury::Snapshot)")
    Treasury::Credit::Evidence::SWEETTALK_CHECK.should be_nil
    note = Treasury::Credit::Note.new(JSON.parse(%({"memo":"renewed","terms":[1,2]})))
    note.raw["memo"].as_s.should eq("renewed")
    Treasury::Credit::Note::SWEETTALK_WRAPS.should eq("::JSON::Any")
    Treasury::Credit::Note::SWEETTALK_CODEC.should eq("::SugarORM::JSONB(::JSON::Any)")
    Treasury::Credit::Note.parse(%({"memo":"renewed","terms":[1,2]})).should eq(note)
    expect_raises(JSON::ParseException) { Treasury::Credit::Evidence.parse(%({"source":"ECB"})) }
    Quote.from_json(%({"rate":"0.05","evidence":{"source":"ECB","base_points":500}}))
      .evidence.should eq(evidence)
  end

  it "keeps a document in a jsonb column, optional, and reads it back whole" do
    SweetTalkSpec.rolled_back do
      loan = DecimalAndJsonValuesSpec.loan
      DecimalAndJsonValuesSpec.column("credit_loans", "evidence").should eq({"jsonb", true})
      DecimalAndJsonValuesSpec.column("credit_loans", "note").should eq({"jsonb", true})
      Treasury::Credit::Loan.find(loan.id).evidence.should be_nil
      evidence = DecimalAndJsonValuesSpec.evidence("ECB", 500)
      loan.reprice(DecimalAndJsonValuesSpec.rate("0.05"), evidence)
      Treasury::Credit::Loan.find(loan.id).evidence.should eq(evidence)
      stored = SugarORM.sql("SELECT evidence->>'source' AS source FROM credit_loans",
        as: {source: String}).first[:source]
      stored.should eq("ECB")
      note = Treasury::Credit::Note.new(JSON.parse(%({"memo":"renewed","terms":[1,2]})))
      loan.annotate(note)
      Treasury::Credit::Loan.find(loan.id).note.should eq(note)
      loan.annotate(nil)
      Treasury::Credit::Loan.find(loan.id).note.should be_nil
    end
  end

  it "finds loans by the whole document, those without one, and reads a specification alike" do
    SweetTalkSpec.rolled_back do
      loans = DecimalAndJsonValuesSpec.loans("0.05", "0.05", "0.05")
      ecb = DecimalAndJsonValuesSpec.evidence("ECB", 500)
      loans[0].reprice(DecimalAndJsonValuesSpec.rate("0.05"), ecb)
      fed = DecimalAndJsonValuesSpec.evidence("Fed", 525)
      loans[1].reprice(DecimalAndJsonValuesSpec.rate("0.05"), fed)
      DecimalAndJsonValuesSpec.ids(Treasury::Credit::Loan.evidenced_by(ecb))
        .should eq([loans[0].id])
      DecimalAndJsonValuesSpec.ids(Treasury::Credit::Loan.unevidenced)
        .should eq([loans[2].id])
      everything = Treasury::Credit::Loan.all
      DecimalAndJsonValuesSpec.agree(Treasury::Credit::Unevidenced, everything, loans, [2])
    end
  end

  it "carries a rate as text and a document as JSON in an event, and feeds a projection" do
    SweetTalkSpec.rolled_back do |connection|
      Treasury::Credit.repricings.clear
      loan = DecimalAndJsonValuesSpec.loan
      evidence = DecimalAndJsonValuesSpec.evidence("ECB", 500)
      repriced = SweetTalk.emitted(Treasury::Credit::Loan::Repriced) do
        loan.reprice(DecimalAndJsonValuesSpec.rate("0.0475"), evidence)
      end.first
      repriced.rate.should eq(DecimalAndJsonValuesSpec.rate("0.0475"))
      repriced.evidence.should eq(evidence)
      DecimalAndJsonValuesSpec.jobs_fields.first.should eq(
        %({"rate":"0.0475","evidence":{"source":"ECB","base_points":500}}))
      Caramel::ColdBrew.drain_queue(connection).should eq(2)
      Treasury::Credit.repricings.should eq(["0.0475|ECB"])
      DecimalAndJsonValuesSpec.column("credit_pricings", "rate")
        .should eq({"numeric(20,8)", true})
      DecimalAndJsonValuesSpec.column("credit_pricings", "evidence")
        .should eq({"jsonb", true})
      row = Treasury::Credit::Pricing.all.first
      row.loan.should eq(loan.id)
      row.rate.should eq(DecimalAndJsonValuesSpec.rate("0.0475"))
      row.evidence.should eq(evidence)
      row.repricings.should eq(1)
    end
  end

  it "refuses a queued event whose rate is not one" do
    meta = %({"id":"e1","at":"2026-03-01T00:00:00.000000Z","by":null,"cause":null,"flow":"f1"})
    repriced = Treasury::Credit::Loan::Repriced
    fields = %({"rate":"0.05","evidence":null})
    queued = repriced.__sweettalk_load(7_i64, fields, meta)
    queued.rate.to_s.should eq("0.05")
    queued.evidence.should be_nil
    expect_raises(SweetTalk::Refusal, "Rate must be at most 1") do
      repriced.__sweettalk_load(7_i64, %({"rate":"7","evidence":null}), meta)
    end
  end
end
