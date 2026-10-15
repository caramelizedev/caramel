require "../../../src/sugar_orm"

struct Team < SugarORM::Schema
  schema "teams" do
    field id : Int64, primary: true
  end
end

struct Book < SugarORM::Schema
  schema "books" do
    field id : Int64, primary: true
    belongs_to team : Team, on_delete: :set_null
  end
end
