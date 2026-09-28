require "spec"
require "../../src/caramel/units"

describe "semantic units (RFC-0008 §2.3)" do
  it "counts sizes as Int64 bytes in binary multiples, past Int32" do
    1.kilobyte.should eq(1024)
    2.megabytes.should eq(2_097_152)
    50.gigabytes.should eq(53_687_091_200)
    1.terabyte.should eq(1_099_511_627_776)
    typeof(50.gigabytes).should eq(Int64)
  end

  it "raises instead of wrapping when a size passes Int64" do
    8_388_607.terabytes.should eq(9_223_370_937_343_148_032)
    expect_raises(OverflowError) { 8_388_608.terabytes }
  end

  it "moves a time to the start of its own day, in its own location" do
    offset = Time::Location.fixed(-5 * 3600)
    midnight = Time.local(2026, 9, 28, 23, 59, 59, location: offset).at_midnight
    midnight.should eq(Time.local(2026, 9, 28, location: offset))
    midnight.location.should eq(offset)
  end
end
