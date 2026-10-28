require "./support/app"
require "../../src/caramel/corretto"

# The tea house's strategic design (ADR 0036) and its shared kernels (ADR 0044). Its card
# gateway is faked at the wire: Corretto.wire starts the suite's wire proxy and points
# Caramel::Outbound at it.
Corretto.wire

describe "SweetTalk strategic design" do
  it "marks each context's subdomain in the glossary" do
    names = %w[Billing Catalogue Insurance Pricing]
    marked = SweetTalk.glossary
      .select { |term| term.kind == "context" && names.includes?(term.name) }
      .map { |term| {term.name, term.subdomain} }
    marked.sort_by(&.[0]).should eq([
      {"Billing", "core"}, {"Catalogue", nil}, {"Insurance", "generic"}, {"Pricing", "supporting"},
    ])
  end

  it "gives every term its context's subdomain, and keeps the four-argument Term" do
    reference = SweetTalk.glossary.find do |term|
      term.kind == "value" && term.name == "Reference" && term.context == "Billing"
    end
    reference.try(&.subdomain).should eq("core")
    term = SweetTalk::Term.new("context", "Ordering", "Ordering", "choosing teas and checking out")
    term.subdomain.should be_nil
  end
end

describe "SweetTalk published languages and outside systems" do
  before_each { Corretto.wire.reset }

  it "bills at the price Pricing publishes, and charges the card at the wire" do
    SweetTalkSpec.committed do
      tea = TeaHouse::Pricing::Tea.create(name: "Sencha", price: TeaHouse::Money::Cents.new(450))
      Corretto.stub_wire("https://cards.example/v1/charges", "POST")
        .to_return(body: %({"id":"ch_1"}), headers: {"Content-Type" => "application/json"})
      id = TeaHouse::Billing.bill(tea.id)
      Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
      bill = TeaHouse::Billing::Bill.find(id)
      {bill.charged?, bill.reference, bill.amount.raw}.should eq({true, "ch_1", 450_i64})
      sent = %({"bill":#{id.raw},"amount":450})
      Corretto.wire_requests.map { |request| {request.method, request.url, request.body} }
        .should eq([{"POST", "https://cards.example/v1/charges", sent}])
    end
  end

  it "declines a bill the card gateway refuses" do
    SweetTalkSpec.committed do
      tea = TeaHouse::Pricing::Tea.create(name: "Sencha", price: TeaHouse::Money::Cents.new(450))
      Corretto.stub_wire("https://cards.example/v1/charges", "POST").to_return(status: 402)
      id = TeaHouse::Billing.bill(tea.id)
      Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
      bill = TeaHouse::Billing::Bill.find(id)
      {bill.declined?, bill.reference}.should eq({true, ""})
    end
  end

  it "leaves a bill open when the gateway is not stubbed" do
    SweetTalkSpec.committed do
      tea = TeaHouse::Pricing::Tea.create(name: "Sencha", price: TeaHouse::Money::Cents.new(450))
      id = TeaHouse::Billing.bill(tea.id)
      Caramel::ColdBrew.drain_queue(SugarORM::Repo.database)
      TeaHouse::Billing::Bill.find(id).open?.should be_true
      Corretto.wire_requests.size.should eq(1)
      errors = SugarORM.sql("SELECT last_error AS value FROM caramel_jobs " \
                            "WHERE last_error IS NOT NULL", as: {value: String})
      errors.first[:value].should contain(
        "Cards answered 502: Unstubbed outbound request: POST https://cards.example/v1/charges")
    end
  end

  it "reads a published service from a border" do
    SweetTalkSpec.committed do
      tea = TeaHouse::Pricing::Tea.create(name: "Sencha", price: TeaHouse::Money::Cents.new(450))
      tea.reprice(TeaHouse::Money::Cents.new(500))
      Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
      TeaHouse::Insurance::Cover.all.map { |cover| {cover.tea, cover.cents} }
        .should eq([{tea.id.raw, 500_i64}])
    end
  end

  it "draws dependency, event and outside edges, and lists the outside system in the glossary" do
    map = SweetTalk.context_map
    map.should contain({"Billing", "Pricing", "dependency"})
    map.should contain({"Insurance", "Pricing", "dependency"})
    map.should contain({"Insurance", "Pricing", "event"})
    map.should contain({"Billing", "Cards", "outside"})
    term = SweetTalk.glossary.find! { |entry| entry.kind == "outside" }
    {term.name, term.context, term.means}
      .should eq({"Cards", "Billing", "the card gateway we charge through"})
  end

  it "keeps Pricing's unpublished service out of reach" do
    TeaHouse::Pricing::SWEETTALK_PUBLISHES.should eq(["Tea::Id", "price_of"])
  end
end

module SharedKernelSpec
  def self.day(text : String) : TeaHouse::Calendar::Day
    TeaHouse::Calendar::Day.new(text)
  end

  def self.cents(amount : Int) : TeaHouse::Money::Cents
    TeaHouse::Money::Cents.new(amount.to_i64)
  end

  def self.tea : TeaHouse::Pricing::Tea
    TeaHouse::Pricing::Tea.create(name: "Sencha", price: cents(450))
  end

  def self.stub_cards : Nil
    Corretto.stub_wire("https://cards.example/v1/charges", "POST")
      .to_return(body: %({"id":"ch_2"}), headers: {"Content-Type" => "application/json"})
  end

  # The column type PostgreSQL holds for *table*'s *column*.
  def self.column_type(table : String, column : String) : String
    query = <<-SQL
      SELECT format_type(a.atttypid, a.atttypmod) AS held
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relname = '#{table}' AND a.attname = '#{column}'
      SQL
    SugarORM.sql(query, as: {held: String}).first[:held]
  end
end

describe "SweetTalk shared kernels" do
  before_each { Corretto.wire.reset }

  it "lets Pricing give a voucher that Billing spends on a bill" do
    SweetTalkSpec.committed do
      tea, expiry = SharedKernelSpec.tea, SharedKernelSpec.day("2026-11-30")
      voucher = TeaHouse::Pricing.give(SharedKernelSpec.cents(100), expiry)
      SharedKernelSpec.stub_cards
      TeaHouse::Billing.spend(voucher, tea.id, SharedKernelSpec.day("2026-11-01"))
      Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
      TeaHouse::Money::Voucher.find(voucher).spent?.should be_true
      TeaHouse::Billing::Bill.all.map { |bill| {bill.amount.raw, bill.charged?} }
        .should eq([{350_i64, true}])
    end
  end

  it "carries a kernel's days in its event, as emitted" do
    SweetTalkSpec.rolled_back do
      tea, expiry = SharedKernelSpec.tea, SharedKernelSpec.day("2026-11-30")
      voucher = TeaHouse::Pricing.give(SharedKernelSpec.cents(100), expiry)
      TeaHouse::Billing.spend(voucher, tea.id, SharedKernelSpec.day("2026-11-01"))
      fields = SugarORM.sql("SELECT payload->>'fields' AS fields FROM caramel_jobs ORDER BY id",
        as: {fields: String}).last[:fields]
      carried = JSON.parse(fields)
      {carried["on"].as_s, carried["expires_on"].as_s}.should eq({"2026-11-01", "2026-11-30"})
    end
  end

  it "refuses a voucher spent after it expires, or spent twice" do
    SweetTalkSpec.rolled_back do
      tea, expiry = SharedKernelSpec.tea, SharedKernelSpec.day("2026-11-30")
      voucher = TeaHouse::Pricing.give(SharedKernelSpec.cents(100), expiry)
      expect_raises(SweetTalk::Refusal, "A voucher cannot be spent after it expires.") do
        TeaHouse::Billing.spend(voucher, tea.id, SharedKernelSpec.day("2026-12-01"))
      end
      TeaHouse::Billing.spend(voucher, tea.id, expiry)
      expect_raises(SweetTalk::Refusal, "Voucher cannot become spent while spent") do
        TeaHouse::Billing.spend(voucher, tea.id, expiry)
      end
    end
  end

  it "finds vouchers by a kernel day in a date column, and keeps a missing day as null" do
    SweetTalkSpec.rolled_back do
      amount, first = SharedKernelSpec.cents(100), SharedKernelSpec.day("2026-11-01")
      last = SharedKernelSpec.day("2026-11-30")
      early = TeaHouse::Pricing.give(amount, SharedKernelSpec.day("2026-11-10"))
      TeaHouse::Pricing.give(amount, SharedKernelSpec.day("2026-12-10"))
      open = TeaHouse::Pricing.give(amount, nil)
      TeaHouse::Money::Voucher.expiring(first, last).map(&.id).should eq([early])
      TeaHouse::Money::Voucher.find(open).expires_on.should be_nil
      SharedKernelSpec.column_type("money_vouchers", "expires_on").should eq("date")
    end
  end

  it "draws kernel edges and lists the kernels in the glossary" do
    SweetTalk.context_map.select(&.[2].==("kernel")).sort!.should eq([
      {"Billing", "Calendar", "kernel"}, {"Billing", "Money", "kernel"},
      {"Money", "Calendar", "kernel"}, {"Pricing", "Calendar", "kernel"},
      {"Pricing", "Money", "kernel"},
    ])
    terms = SweetTalk.glossary.select { |term| {"Money", "Calendar"}.includes?(term.context) }
      .map { |term| {term.kind, term.name, term.context} }
    terms.should contain({"kernel", "Money", "Money"})
    terms.should contain({"kernel", "Calendar", "Calendar"})
    terms.should contain({"value", "Cents", "Money"})
    terms.should contain({"aggregate", "Voucher", "Money"})
    terms.should contain({"event", "Voucher::Spent", "Money"})
    terms.should contain({"value", "Day", "Calendar"})
  end
end
