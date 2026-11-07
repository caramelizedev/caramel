require "../../../src/sugar_orm"

struct Player < SugarORM::Schema
  schema "players" do
    field id : UUID, primary: true
    belongs_to team : Team
  end
end

struct Team < SugarORM::Schema
  schema "teams" do
    field id : UUID, primary: true
  end
end

class Player::CreateChangeset < SugarORM::Changeset(Player)
  param team_id : Int64
end
