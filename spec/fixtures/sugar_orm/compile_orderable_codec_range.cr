require "../../../src/sugar_orm"

struct Task < SugarORM::Schema
  schema "tasks" do
    field id : Int64, primary: true
    field due_on : SugarORM::Date, codec: SugarORM::DateCodec
    field done_on : SugarORM::Date?, codec: SugarORM::DateCodec
  end
end

first = SugarORM::Date.new(2026, 10, 1)
last = SugarORM::Date.new(2026, 10, 31)
Task::Query.where(due_on: first..last, done_on: ..last).to_sql
Task::Query.where(due_on: first...last).order_by(:due_on, :desc).to_sql
Task::Query.where(due_on: first..).to_sql
