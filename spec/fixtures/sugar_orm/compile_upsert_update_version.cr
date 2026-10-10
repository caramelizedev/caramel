require "../../../src/sugar_orm"

struct Sale < SugarORM::Schema
  schema "sales" do
    field id : Int64, primary: true
    field tea_id : Int64
    field lock_version : Int32, version: true
    index :tea_id, unique: true
  end
end

class Sale::Upsert < SugarORM::Changeset(Sale)
  param tea_id : Int64
  param lock_version : Int32
  upsert on: :tea_id, update: [:lock_version]
end
