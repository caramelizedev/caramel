require "spec"
require "./support/unit_schemas"

# What libraries outside the framework use of a schema; each declaration's comment says
# so. An example that fails, or no longer compiles, means such a library breaks.
# `SUGAR_TENANT` on a tenanted schema is proved by spec/fixtures/tenancy/compile_valid.cr.

private alias Date = SugarORM::Date
private alias Deadline = SugarUnit::Deadline
private alias Quote = SugarUnit::Quote

private FIRST = Date.new(2026, 1, 2)
private LAST  = Date.new(2026, 3, 4)

describe "SugarORM's hooks for libraries" do
  it "names the primary key's type for macros in SUGAR_KEY" do
    {{ SugarUnit::Counter.constant(:SUGAR_KEY) }}.should eq("Int64")
    {{ SugarUnit::Badge.constant(:SUGAR_KEY) }}.should eq("UUID")
  end

  it "gives a schema with no tenant no SUGAR_TENANT" do
    {{ SugarUnit::Counter.has_constant?(:SUGAR_TENANT) }}.should be_false
  end

  it "gives a record's primary key through __sugar_primary_value" do
    counter = SugarUnit::Counter.new(id: 7_i64, label: "tea")
    counter.__sugar_primary_value.should eq(7_i64)
    typeof(counter.__sugar_primary_value).should eq(Int64)
  end

  it "gives a UUID key through __sugar_primary_value" do
    id = UUID.v7
    badge = SugarUnit::Badge.new(id: id, label: "host", team_id: 1_i64)
    badge.__sugar_primary_value.should eq(id)
    typeof(badge.__sugar_primary_value).should eq(UUID)
  end

  it "encodes a codec column's value through __sugar_encode_<column>" do
    Quote.__sugar_encode_price(value: "1.50").should eq("1.50")
    SugarUnit::Ticket.__sugar_encode_grade(value: SugarUnit::Grade::Premium).should eq("Premium")
    Deadline.__sugar_encode_due_on(value: FIRST).should eq("2026-01-02")
    typeof(Quote.__sugar_encode_price(value: "1.50")).should eq(String?)
  end

  it "encodes nil as nil" do
    Quote.__sugar_encode_fee(value: nil).should be_nil
    Quote.__sugar_encode_price(value: nil).should be_nil
  end

  it "encodes both ends of an orderable codec column's range" do
    closed = Deadline.__sugar_encode_due_on(value: FIRST..LAST)
    closed.should eq("2026-01-02".."2026-03-04")
    typeof(closed).should eq(Range(String, String))
    Deadline.__sugar_encode_due_on(value: FIRST...LAST).excludes_end?.should be_true
  end

  it "encodes the one end of an open range" do
    endless = Deadline.__sugar_encode_due_on(value: FIRST..)
    endless.should eq("2026-01-02"..)
    typeof(endless).should eq(Range(String, Nil))
    beginless = Deadline.__sugar_encode_due_on(value: ..LAST)
    beginless.should eq(.."2026-03-04")
    typeof(beginless).should eq(Range(Nil, String))
  end

  it "passes the value of a column with no codec through" do
    SugarUnit::Counter.__sugar_encode_label(value: "tea").should eq("tea")
    SugarUnit::Counter.__sugar_encode_id(value: 7_i64).should eq(7_i64)
    SugarUnit::Counter.__sugar_encode_label(value: nil).should be_nil
  end
end
