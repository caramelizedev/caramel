# What a screen reads of the domain's closed sets (ADR 0058): a closed-set value's member as
# an enum, and a lifecycle's graph.
require "./support/app"

module ClosedSetsSpec
  alias Roast = TeaShop::Catalogue::Roast
  alias Kind = Ledger::Counter::Kind
  alias Order = TeaShop::Ordering::Order
  alias State = TeaShop::Ordering::Order::State

  # The CHECK on the roast column; its suffix is the FNV-1a hash of "dark,light,medium",
  # the same with or without the member enum.
  ROAST_CHECK = <<-SQL
    SELECT conname::text AS conname FROM pg_constraint
    WHERE conname LIKE 'check_catalogue_teas_roast_one_of_%'
    SQL

  # A label per roast, as a view writes it: the case names every member, and no else.
  def self.label(roast : Roast) : String
    case roast.member
    in .light?  then "Light roast"
    in .medium? then "Medium roast"
    in .dark?   then "Dark roast"
    end
  end

  def self.order(*lines) : Order
    account = TeaShop::Account.create!(email: "ada@example.com")
    postcode = TeaShop::Ordering::Postcode.new("CA1 1TE")
    address = TeaShop::Ordering::Address.new(street: "1 Leaf Lane", city: "Camellia",
      postcode: postcode)
    order = Order.open(account, TeaShop::Ordering::Email.new("ada@example.com"), address)
    lines.each { |(tea, tins)| order.add tea, TeaShop::Ordering::Quantity.new(tins) }
    order
  end

  def self.tea(stock : Int32) : TeaShop::Catalogue::Tea
    TeaShop::Catalogue::Tea.create(name: "Sencha", price: TeaShop::Catalogue::Cents.new(900),
      stock: TeaShop::Catalogue::Tins.new(stock))
  end
end

describe "SweetTalk's closed-set members" do
  it "gives every member an enum member, in the order one_of: lists them" do
    ClosedSetsSpec::Kind.all.map(&.member).should eq([
      ClosedSetsSpec::Kind::Member::Payment,
      ClosedSetsSpec::Kind::Member::Receipt,
      ClosedSetsSpec::Kind::Member::NetSettlement,
    ])
  end

  it "builds the value of a member, the way back from member" do
    kind = ClosedSetsSpec::Kind.new(ClosedSetsSpec::Kind::Member::NetSettlement)
    kind.should eq(ClosedSetsSpec::Kind.net_settlement)
    kind.raw.should eq("net_settlement")
    ClosedSetsSpec::Kind.new(:receipt).receipt?.should be_true
  end

  it "branches on a member in a case that names every one" do
    labels = ClosedSetsSpec::Roast.all.map { |roast| ClosedSetsSpec.label(roast) }
    labels.should eq(["Light roast", "Medium roast", "Dark roast"])
  end

  it "keeps storing the word, under the check named by the hash of the words" do
    SweetTalkSpec.rolled_back do
      tea = ClosedSetsSpec.tea(3)
      tea.roast.member.should eq(ClosedSetsSpec::Roast::Member::Medium)
      SugarORM.sql("SELECT roast FROM catalogue_teas", as: {roast: String})
        .should eq([{roast: "medium"}])
      SugarORM.sql(ClosedSetsSpec::ROAST_CHECK, as: {conname: String})
        .should eq([{conname: "check_catalogue_teas_roast_one_of_59746504"}])
    end
  end
end

describe "SweetTalk's lifecycle graph" do
  it "lists the states a mover may enter from each state, in the order moves names them" do
    order = ClosedSetsSpec::Order
    order.moves_from(:open).should eq([ClosedSetsSpec::State::Placed,
                                       ClosedSetsSpec::State::Cancelled])
    order.moves_from(:placed).should eq([ClosedSetsSpec::State::Shipped,
                                         ClosedSetsSpec::State::Cancelled])
    order.moves_from(:shipped).should be_empty
    order.moves_from(:cancelled).should be_empty
  end

  it "answers whether a mover may enter a state from the current one, as the order moves" do
    SweetTalkSpec.rolled_back do
      order = ClosedSetsSpec.order({ClosedSetsSpec.tea(3), 1})
      order.may_become?(:placed).should be_true
      order.may_become?(:shipped).should be_false
      order.place
      order.may_become?(:shipped).should be_true
      order.may_become?(:placed).should be_false
      order.cancel
      ClosedSetsSpec::State.values.none? { |state| order.may_become?(state) }.should be_true
    end
  end
end
