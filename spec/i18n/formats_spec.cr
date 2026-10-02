require "spec"
require "./support/app"

private alias Locale = Caramel::Locale

private AFTERNOON = Time.utc(2026, 10, 1, 14, 5)
private MIDNIGHT  = Time.utc(2026, 10, 1, 0, 30)

describe "Caramel::Localized#l" do
  it "writes a number with the locale's separator and delimiter" do
    I18nSpec.l(Locale::En, 1234.5, 2).should eq("1,234.50")
    I18nSpec.l(Locale::Fr, 1234.5, 2).should eq("1 234,50")
  end

  it "writes a date with the locale's pattern and month names" do
    I18nSpec.l(Locale::En, AFTERNOON, :date).should eq("October 1, 2026")
    I18nSpec.l(Locale::Fr, AFTERNOON, :date).should eq("1 octobre 2026")
  end

  it "writes a 12-hour time with AM and PM" do
    I18nSpec.l(Locale::En, AFTERNOON, :time).should eq("2:05 PM")
    I18nSpec.l(Locale::En, MIDNIGHT, :time).should eq("12:30 AM")
  end

  it "writes a 24-hour time where the locale's pattern asks for one" do
    I18nSpec.l(Locale::Fr, AFTERNOON, :time).should eq("14:05")
  end

  it "falls back to the default locale's patterns and names" do
    I18nSpec.l(Locale::Ru, AFTERNOON, :short_date).should eq("Oct 1")
  end
end
