require "spec"
require "../../src/sugar_orm"
require "../../src/sugar_orm/decimal"

private alias Rates = SugarORM::DecimalCodec(20, 8)

module SugarUnitDecimal
  struct Price < SugarORM::Schema
    schema "unit_prices" do
      field id : Int64, primary: true
      field rate : BigDecimal, codec: SugarORM::DecimalCodec(20, 8)
      field fee : BigDecimal?, codec: SugarORM::DecimalCodec(6, 2)
    end
  end
end

private alias Price = SugarUnitDecimal::Price

describe SugarORM::DecimalCodec do
  it "names numeric(P,S) as its column type and declares itself orderable" do
    Rates.sql_type.should eq("numeric(20,8)")
    SugarORM::DecimalCodec(6, 2).sql_type.should eq("numeric(6,2)")
    Rates::ORDERABLE.should be_true
    SugarORM::Codec.checked_sql_type(Rates.sql_type).should eq("numeric(20,8)")
  end

  it "writes plain digits, never an exponent, and reads them back exact" do
    Rates.encode(BigDecimal.new("0.5")).should eq("0.5")
    Rates.encode(BigDecimal.new("0.50000000")).should eq("0.5")
    Rates.encode(BigDecimal.new("-12.25")).should eq("-12.25")
    Rates.encode(BigDecimal.new("100")).should eq("100")
    Rates.encode(BigDecimal.new("0")).should eq("0")
    Rates.encode(BigDecimal.new("-0")).should eq("0")
    big = "123456789012.12345678"
    Rates.encode(BigDecimal.new(big)).should eq(big)
    Rates.decode(big).should eq(BigDecimal.new(big))
    wider = "12345678901234567890.12345678"
    BigDecimal.new(wider).to_s.should contain("e+")
    SugarORM::Decimal.plain(BigDecimal.new(wider)).should eq(wider)
    SugarORM::DecimalCodec(40, 8).encode(BigDecimal.new(wider)).should eq(wider)
    Rates.decode("0.50000000").should eq(BigDecimal.new("0.5"))
    Rates.decode(Rates.encode(BigDecimal.new("0.00000001"))).should eq(BigDecimal.new("0.00000001"))
    expect_raises(InvalidBigDecimalException) { Rates.decode("NaN") }
  end

  it "refuses at the write more decimals than S, or more digits than P - S before the point" do
    error = expect_raises(ArgumentError, "does not fit numeric(20,8)") do
      Rates.encode(BigDecimal.new("0.123456789"))
    end
    error.message.not_nil!.should contain("at most 8 decimals and 12 digits before the point")
    expect_raises(ArgumentError, "1234567890123 does not fit numeric(20,8)") do
      Rates.encode(BigDecimal.new("1234567890123"))
    end
    Rates.encode(BigDecimal.new("123456789012")).should eq("123456789012")
    Rates.encode(BigDecimal.new("0.12345678")).should eq("0.12345678")
    SugarORM::DecimalCodec(8, 8).encode(BigDecimal.new("0.5")).should eq("0.5")
    expect_raises(ArgumentError, "does not fit numeric(8,8)") do
      SugarORM::DecimalCodec(8, 8).encode(BigDecimal.new("1.5"))
    end
  end

  it "takes a value, nil or a Range in where, binding the encoded text" do
    half = BigDecimal.new("0.5")
    one = BigDecimal.new("1")
    exact = Price.query.where(rate: half)
    exact.to_sql.should end_with(%(WHERE "rate" = $1))
    exact.binds.should eq(["0.5"] of SugarORM::Value)
    closed = Price.query.where(rate: half..one)
    closed.to_sql.should end_with(%(WHERE "rate" BETWEEN $1 AND $2))
    closed.binds.should eq(["0.5", "1"] of SugarORM::Value)
    half_open = Price.query.where(rate: half...one)
    half_open.to_sql.should end_with(%(WHERE "rate" >= $1 AND "rate" < $2))
    Price.query.where(rate: half..).to_sql.should end_with(%(WHERE "rate" >= $1))
    Price.query.where(rate: ..one).to_sql.should end_with(%(WHERE "rate" <= $1))
    Price.query.where(fee: nil).to_sql.should end_with(%(WHERE "fee" IS NULL))
    ordered = Price.query.where(fee: BigDecimal.new("2.5")..).order_by(:rate, :desc)
    ordered.to_sql.should end_with(%(WHERE "fee" >= $1 ORDER BY "rate" DESC))
    ordered.binds.should eq(["2.5"] of SugarORM::Value)
    expect_raises(ArgumentError, "does not fit numeric(6,2)") do
      Price.query.where(fee: BigDecimal.new("0.125"))
    end
  end

  it "declares numeric(P,S) columns in the catalog" do
    table = SugarORM::Catalog.declared.find! { |declared| declared.name == "unit_prices" }
    rate = table.columns.find! { |column| column.name == "rate" }
    {rate.sql_type, rate.nullable}.should eq({"numeric(20,8)", false})
    fee = table.columns.find! { |column| column.name == "fee" }
    {fee.sql_type, fee.nullable}.should eq({"numeric(6,2)", true})
  end
end
