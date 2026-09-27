require "./schemas"

class Team::SeatsChangeset < SugarORM::Changeset(Team)
  param seats : String
end
