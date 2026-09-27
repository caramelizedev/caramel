require "../../../src/sugar_orm"

struct Keyless < SugarORM::Schema
  schema "keyless" do
    field name : String
  end
end
