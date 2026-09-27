require "./schemas"

team = Team.query.find!(1)
Team::UpdateChangeset.new(team, name: "Renamed")
