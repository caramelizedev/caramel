require "./support/app"
require "../../src/caramel/corretto"

# The tea house's strategic design (ADR 0036). Its card gateway is faked at the wire:
# Corretto.wire starts the suite's wire proxy and points Caramel::Outbound at it.
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
      tea = TeaHouse::Pricing::Tea.create(name: "Sencha", price: TeaHouse::Pricing::Cents.new(450))
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
      tea = TeaHouse::Pricing::Tea.create(name: "Sencha", price: TeaHouse::Pricing::Cents.new(450))
      Corretto.stub_wire("https://cards.example/v1/charges", "POST").to_return(status: 402)
      id = TeaHouse::Billing.bill(tea.id)
      Caramel::ColdBrew.drain_queue!(SugarORM::Repo.database)
      bill = TeaHouse::Billing::Bill.find(id)
      {bill.declined?, bill.reference}.should eq({true, ""})
    end
  end

  it "leaves a bill open when the gateway is not stubbed" do
    SweetTalkSpec.committed do
      tea = TeaHouse::Pricing::Tea.create(name: "Sencha", price: TeaHouse::Pricing::Cents.new(450))
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
      tea = TeaHouse::Pricing::Tea.create(name: "Sencha", price: TeaHouse::Pricing::Cents.new(450))
      tea.reprice(TeaHouse::Pricing::Cents.new(500))
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
    TeaHouse::Pricing::SWEETTALK_PUBLISHES.should eq(["Cents", "Tea::Id", "price_of"])
  end
end
