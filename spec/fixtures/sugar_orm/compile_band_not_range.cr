require "../../../src/sugar_orm"

struct Shelf < SugarORM::Schema
  schema "band_shelves" do
    field id : Int64, primary: true
    field stock : Int32 = 0
    band stock, many: "lots"
  end
end
