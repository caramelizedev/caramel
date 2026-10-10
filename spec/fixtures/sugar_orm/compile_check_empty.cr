require "../../../src/sugar_orm"

struct Room < SugarORM::Schema
  schema "rooms" do
    field id : Int64, primary: true
    field seats : Int32
    check seats: 10..1
  end
end
