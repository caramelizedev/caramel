require "../../../src/sugar_orm"

struct Task < SugarORM::Schema
  schema "tasks" do
    field id : Int64, primary: true
    field due_on : SugarORM::Date, codec: SugarORM::DateCodec
  end
end

Task::Query.where(due_on: 1..5).to_a
