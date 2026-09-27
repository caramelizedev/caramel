require "../../../src/sugar_orm"

struct Season < SugarORM::Schema
  schema "seasons" do
    field id : Int64, primary: true
    field year : Int32 = Time.utc.year
  end
end
