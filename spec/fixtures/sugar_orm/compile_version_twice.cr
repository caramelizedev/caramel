require "../../../src/sugar_orm"

struct Counter < SugarORM::Schema
  schema "counters" do
    field id : Int64, primary: true
    field lock_version : Int32, version: true
    field revision : Int64, version: true
  end
end
