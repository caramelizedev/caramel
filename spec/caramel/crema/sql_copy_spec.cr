require "spec"
require "../../../src/caramel/crema/sql_copy"

alias Bindable = Bool? | Int32 | Int64 | Float64 | String | Time | Bytes |
                 Array(Int32) | Array(String)

describe Caramel::Crema::Literal do
  it "writes each type as a PostgreSQL literal" do
    literal = ->(value : Bindable) { Caramel::Crema::Literal.of(value) }
    literal.call(nil).should eq("NULL")
    literal.call(42).should eq("42")
    literal.call(42_i64).should eq("42")
    literal.call(1.5).should eq("1.5")
    literal.call(Float64::NAN).should eq("'NaN'")
    literal.call(true).should eq("true")
    literal.call("it's a \\ path").should eq("'it''s a \\ path'")
    literal.call(Time.utc(2026, 10, 7, 12, 0, 0)).should eq("'2026-10-07T12:00:00.000000Z'")
    literal.call([1, 2]).should eq("ARRAY[1,2]")
    literal.call(["a", "b'c"]).should eq("ARRAY['a','b''c']")
    literal.call([] of Int32).should eq("'{}'")
    literal.call(Bytes[1, 255]).should eq("'\\x01ff'")
  end

  it "leaves a value longer than the limit as its placeholder" do
    long = "x" * (Caramel::Crema::SqlCopy::MAX_LITERAL + 1)
    Caramel::Crema::Literal.of(long).should eq("")
    Caramel::Crema::SqlCopy.fill("SELECT $1, $2", ["", "2"]).should eq("SELECT $1, 2")
  end
end

describe Caramel::Crema::SqlCopy do
  it "substitutes in one pass, so $1 never hits $10, and skips quoted text" do
    sql = "SELECT $1, $10, 'costs $1', $11"
    values = (1..10).map(&.to_s)
    Caramel::Crema::SqlCopy.fill(sql, values).should eq("SELECT 1, 10, 'costs $1', $11")
  end

  it "leaves comments, identifiers and dollar-quoted bodies alone" do
    sql = %(SELECT $1 -- it's $1\n, "a$1" /* $1 */, $$ $1 $$, $tag$ $1 $tag$, $2)
    filled = Caramel::Crema::SqlCopy.fill(sql, ["1", "2"])
    filled.should eq(%(SELECT 1 -- it's $1\n, "a$1" /* $1 */, $$ $1 $$, $tag$ $1 $tag$, 2))
  end

  it "reads E'' strings with backslash escapes, and plain strings without them" do
    fill = ->(sql : String) { Caramel::Crema::SqlCopy.fill(sql, ["1"]) }
    fill.call(%(SELECT E'a\\'b $1', $1)).should eq(%(SELECT E'a\\'b $1', 1))
    fill.call(%(SELECT E'a\\\\', $1)).should eq(%(SELECT E'a\\\\', 1))
    fill.call(%(SELECT '\\', $1)).should eq(%(SELECT '\\', 1))
    fill.call(%(SELECT 'it''s $1', $1)).should eq(%(SELECT 'it''s $1', 1))
    fill.call(%(SELECT e'x $1', $1)).should eq(%(SELECT e'x $1', 1))
  end

  it "does not fail on an absurdly long placeholder number" do
    sql = "SELECT $99999999999999999999"
    Caramel::Crema::SqlCopy.fill(sql, ["1"]).should eq(sql)
  end

  it "says when a placeholder is left outside a string" do
    Caramel::Crema::SqlCopy.unfilled?("SELECT $2, 'a $1'").should be_true
    Caramel::Crema::SqlCopy.unfilled?("SELECT 2, 'a $1'").should be_false
  end
end
