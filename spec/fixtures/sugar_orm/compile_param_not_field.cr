require "./schemas"

class Team::RenameChangeset < SugarORM::Changeset(Team)
  param nickname : String
end
