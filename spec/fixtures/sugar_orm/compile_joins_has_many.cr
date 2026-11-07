require "./schemas"

Team.query.joins(:users).to_a
