require "spec"
require "json"
require "../../src/sugar_orm/date"

private alias Day = SugarORM::Date

describe SugarORM::Date do
  it "holds a year, a month and a day, and prints them as YYYY-MM-DD" do
    day = Day.new(2026, 10, 24)
    day.year.should eq(2026)
    day.month.should eq(10)
    day.day.should eq(24)
    day.to_s.should eq("2026-10-24")
    Day.new(7, 1, 2).to_s.should eq("0007-01-02")
    day.inspect.should eq("SugarORM::Date(2026-10-24)")
  end

  it "refuses a day that does not exist" do
    [{2026, 2, 30}, {2025, 2, 29}, {2026, 13, 1}, {2026, 0, 1}, {2026, 4, 31},
     {0, 1, 1}, {10_000, 1, 1}, {2026, 1, 0}].each do |year, month, day|
      expect_raises(ArgumentError, "is not a calendar day") { Day.new(year, month, day) }
    end
    Day.new(2024, 2, 29).to_s.should eq("2024-02-29")
    Day.new(1, 1, 1).to_s.should eq("0001-01-01")
    Day.new(9999, 12, 31).to_s.should eq("9999-12-31")
  end

  it "parses YYYY-MM-DD and nothing else" do
    Day.parse("2026-10-24").should eq(Day.new(2026, 10, 24))
    ["", "2026-1-5", "2026-10-24 ", " 2026-10-24", "2026-10-24\n", "10/11/2026", "today",
     "infinity", "-infinity", "0044-03-15 BC", "2026-02-30", "0000-01-01", "２０２６-10-24",
     "2026-10-24T00:00:00Z"].each do |text|
      Day.parse?(text).should be_nil
      expect_raises(ArgumentError, "is not a YYYY-MM-DD calendar day") { Day.parse(text) }
    end
  end

  it "orders by year, then month, then day, and hashes by value" do
    days = [Day.new(2026, 10, 24), Day.new(2025, 12, 31), Day.new(2026, 2, 1), Day.new(2026, 10, 3)]
    days.sort.map(&.to_s).should eq(["2025-12-31", "2026-02-01", "2026-10-03", "2026-10-24"])
    (Day.new(2026, 1, 1) < Day.new(2026, 1, 2)).should be_true
    Day.new(2026, 1, 1).should eq(Day.new(2026, 1, 1))
    {Day.new(2026, 1, 1) => 1}[Day.new(2026, 1, 1)].should eq(1)
    (Day.new(2026, 1, 1)..Day.new(2026, 1, 31)).includes?(Day.new(2026, 1, 15)).should be_true
  end

  it "moves by days across months, years and leap days" do
    Day.new(2026, 10, 24).plus_days(8).should eq(Day.new(2026, 11, 1))
    Day.new(2026, 1, 1).plus_days(-1).should eq(Day.new(2025, 12, 31))
    Day.new(2024, 2, 28).plus_days(2).should eq(Day.new(2024, 3, 1))
    Day.new(2026, 10, 24).plus_days(0).should eq(Day.new(2026, 10, 24))
    Day.new(2026, 10, 24).days_until(Day.new(2026, 11, 1)).should eq(8)
    Day.new(2026, 11, 1).days_until(Day.new(2026, 10, 24)).should eq(-8)
    expect_raises(ArgumentError, "outside year 1 to 9999") { Day.new(9999, 12, 31).plus_days(1) }
    expect_raises(ArgumentError, "outside year 1 to 9999") { Day.new(1, 1, 1).plus_days(-1) }
  end

  it "names its weekday and converts to and from a Time without a zone shift" do
    Day.new(2026, 10, 24).day_of_week.should eq(Time::DayOfWeek::Saturday)
    Day.new(2026, 10, 24).to_time.should eq(Time.utc(2026, 10, 24))
    late = Time.utc(2026, 10, 24, 23, 59, 59)
    Day.of(late).should eq(Day.new(2026, 10, 24))
    zoned = Time.local(2026, 10, 24, 1, 30, location: Time::Location.fixed("east", 10 * 3600))
    zoned.to_utc.day.should eq(23)
    Day.of(zoned).should eq(Day.new(2026, 10, 24))
  end

  it "is a string in JSON, and reads only a valid day back" do
    day = Day.new(2026, 10, 24)
    day.to_json.should eq(%("2026-10-24"))
    {"due" => day}.to_json.should eq(%({"due":"2026-10-24"}))
    Day.from_json(%("2026-10-24")).should eq(day)
    expect_raises(JSON::ParseException, "expected a YYYY-MM-DD calendar day") do
      Day.from_json(%("2026-02-30"))
    end
  end
end

describe SugarORM::DateCodec do
  it "names the date column type and round trips YYYY-MM-DD" do
    SugarORM::DateCodec.sql_type.should eq("date")
    day = Day.new(2026, 10, 24)
    SugarORM::DateCodec.encode(day).should eq("2026-10-24")
    SugarORM::DateCodec.decode("2026-10-24").should eq(day)
    first = Day.new(1, 1, 1)
    SugarORM::DateCodec.decode(SugarORM::DateCodec.encode(first)).should eq(first)
  end

  it "declares itself orderable" do
    SugarORM::DateCodec::ORDERABLE.should be_true
  end

  it "refuses what a date column prints outside the ISO styles, infinity and BC dates" do
    ["24.10.2026", "Sat 24 Oct 2026", "10/24/2026", "infinity", "-infinity", "0044-03-15 BC",
     ""].each do |text|
      error = expect_raises(ArgumentError, "is not a YYYY-MM-DD day") do
        SugarORM::DateCodec.decode(text)
      end
      error.message.not_nil!.should contain(text.inspect)
      error.message.not_nil!.should contain("DateStyle")
    end
  end
end
