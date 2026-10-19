require "../../../src/sugar_orm"

struct Team < SugarORM::Schema
  schema "teams" do
    field id : Int64, primary: true
    field name : String
  end
end

puts({record: Team.new(id: 1_i64, name: "Acme")}.to_json)
