require "../../../src/sugar_orm"

# A schema may reference one keyed by UUID that is declared after it.
struct Member < SugarORM::Schema
  schema "members" do
    field id : Int64, primary: true
    field name : String
    belongs_to squad : Squad
    belongs_to mentor : Squad?
  end
end

struct Squad < SugarORM::Schema
  schema "squads" do
    field id : UUID, primary: true
    field name : String
    belongs_to league : League
    has_many members : Member
  end
end

struct League < SugarORM::Schema
  schema "leagues" do
    field id : Int64, primary: true
    field name : String
    has_many squads : Squad
  end
end

class Squad::CreateChangeset < SugarORM::Changeset(Squad)
  param id : UUID
  param name : String
  param league_id : Int64
end

class Member::CreateChangeset < SugarORM::Changeset(Member)
  param name : String
  param squad_id : UUID
  param mentor_id : UUID?
end

def compile_uuid_valid : Nil
  first, last = SugarORM.uuid7, SugarORM.uuid7
  squad = Squad::CreateChangeset.new(id: first, name: "Reds", league_id: 1_i64)
  squad_id : UUID = squad.id
  Member::CreateChangeset.new(name: "Ada", squad_id: squad_id, mentor_id: nil)
  Member.create(name: "Ada", squad_id: squad_id)
  Squad.query.find(first).try(&.league_id)
  Squad.query.where(id: first..last).to_a
  Member.query.where(squad_id: first..last).where(mentor_id: [first, last]).to_a
  Member.query.preload(:squad).preload(:mentor).to_a.map(&.squad.name)
  Squad.query.preload(:members).preload(:league).to_a.map(&.members.size)
  page = Squad.query.page(10, after: first)
  Squad.query.page(10, after: page.after)
  Squad.query.each_batch(10) { |batch| batch.map(&.name) }
end

compile_uuid_valid if ARGV.size > 99
