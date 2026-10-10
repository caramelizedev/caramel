require "./schemas"

class Team::Upsert < SugarORM::Changeset(Team)
  param name : String
  upsert on: :name, update: [:name]
end
