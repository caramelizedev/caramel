require "../../../src/sugar_orm"

struct Tagged < SugarORM::Schema
  schema "tagged" do
    field id : Int64, primary: true
    field tags : Array(String)
  end
end
