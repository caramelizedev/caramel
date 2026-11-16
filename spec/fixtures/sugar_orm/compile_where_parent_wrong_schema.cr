require "./schemas"

Team::Query.where(owner: Team.query).to_a
