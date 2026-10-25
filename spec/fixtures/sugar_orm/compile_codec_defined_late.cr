require "../../../src/sugar_orm"

struct Task < SugarORM::Schema
  schema "tasks" do
    field id : Int64, primary: true
    field due_on : SugarORM::Date, codec: LateCodec
  end
end

module LateCodec
  ORDERABLE = true

  def self.sql_type : String
    "date"
  end

  def self.encode(value : SugarORM::Date) : String
    value.to_s
  end

  def self.decode(text : String) : SugarORM::Date
    SugarORM::Date.parse(text)
  end
end

first = SugarORM::Date.new(2026, 10, 1)
Task::Query.where(due_on: first..).to_a
