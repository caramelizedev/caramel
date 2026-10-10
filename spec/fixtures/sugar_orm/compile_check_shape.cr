require "../../../src/sugar_orm"

struct Room < SugarORM::Schema
  schema "rooms" do
    field id : Int64, primary: true
    field stock : Int32
    check :stock
  end
end
