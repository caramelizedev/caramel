require "../../../src/sugar_orm"

struct Team < SugarORM::Schema
  schema "teams" do
    field id : Int64, primary: true
    field name : String
    json :id
    json :id, :name
  end
end
