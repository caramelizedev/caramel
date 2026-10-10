require "./schemas"

class Team::Upsert < SugarORM::Changeset(Team)
  param seats : Int32
  upsert on: :seats
end
