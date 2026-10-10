require "../../../src/sugar_orm"

struct Room < SugarORM::Schema
  schema "rooms" do
    field id : Int64, primary: true
    field seats : Int32
    check beds: 0..
  end
end
