require "../../../src/sugar_orm"

struct Room < SugarORM::Schema
  schema "rooms" do
    field id : Int64, primary: true
    field name : String
    check name: 0..
  end
end
