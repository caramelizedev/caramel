# What a screen reads of the domain's closed sets (ADR 0058): a closed-set value's member as
# an enum.
require "./support/app"

module ClosedSetsSpec
  alias Roast = TeaShop::Catalogue::Roast
  alias Kind = Ledger::Counter::Kind

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
