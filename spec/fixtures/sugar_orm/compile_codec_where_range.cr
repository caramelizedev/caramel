require "../../../src/sugar_orm"

module PlainCodec
  def self.sql_type : String
    "numeric(20,8)"
  end

  def self.encode(value : Int32) : String
    value.to_s
  end

  def self.decode(text : String) : Int32
    text.to_i
  end
end

struct Priced < SugarORM::Schema
  schema "priced" do
    field id : Int64, primary: true
    field price : Int32, codec: PlainCodec
  end
end

Priced::Query.where(price: 1..5).to_a
