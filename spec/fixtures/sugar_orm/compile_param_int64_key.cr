require "../../../src/sugar_orm"

struct Fixture < SugarORM::Schema
  schema "fixtures" do
    field id : Int64, primary: true
    field name : String
  end
end

class Fixture::CreateChangeset < SugarORM::Changeset(Fixture)
  param id : Int64
end
