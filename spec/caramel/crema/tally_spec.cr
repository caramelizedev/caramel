require "spec"
require "../../../src/caramel/crema"

describe Caramel::Crema::Histogram do
  it "puts a value equal to a bound in that bound's bucket" do
    histogram = Caramel::Crema::Histogram.new
    histogram.observe(5.0)
    histogram.observe(5.1)
    histogram.counts[0].should eq(1)
    histogram.counts[1].should eq(1)
  end

  it "interpolates a quantile inside its bucket as Prometheus does" do
    histogram = Caramel::Crema::Histogram.new
    10.times { histogram.observe(20.0) }
    # All ten fall in (10, 25]; the median is halfway through that bucket.
    histogram.quantile(0.5, 20.0).should eq(17.5)
  end

  it "answers the maximum for a quantile in the overflow bucket" do
    histogram = Caramel::Crema::Histogram.new
    histogram.observe(20_000.0)
    histogram.quantile(0.99, 20_000.0).should eq(20_000.0)
  end

  it "never answers more than the maximum" do
    histogram = Caramel::Crema::Histogram.new
    10.times { histogram.observe(20.0) }
    histogram.quantile(1.0, 12.0).should eq(12.0)
  end
end

describe Caramel::Crema::Tally do
  it "aggregates by kind and key, and starts empty after a swap" do
    tally = Caramel::Crema::Tally.new
    tally.record("request", "GET /", 4.0, false)
    tally.record("request", "GET /", 30.0, true)
    filled = tally.swap
    entry = filled["request", "GET /"].not_nil!
    {entry.count, entry.errors, entry.total_ms, entry.max_ms}.should eq({2, 1, 34.0, 30.0})
    tally.size.should eq(0)
  end

  it "folds rows beyond the cap into (other) and copies a snapshot" do
    tally = Caramel::Crema::Tally.new(2)
    %w[a b c d].each { |key| tally.record("request", key, 1.0, false) }
    tally.size.should eq(3)
    copy = tally.snapshot
    tally.record("request", "a", 1.0, false)
    other = copy.find! { |row| row[1] == "(other)" }[2]
    other.count.should eq(2)
    copy.find! { |row| row[1] == "a" }[2].count.should eq(1)
  end
end
