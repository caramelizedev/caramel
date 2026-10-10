require "../../../src/sugar_orm"

struct Tea < SugarORM::Schema
  schema "teas" do
    field id : Int64, primary: true
  end
end

struct Blend < SugarORM::Schema
  schema "teas" do
    field id : Int64, primary: true
  end
end
