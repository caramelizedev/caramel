require "./schemas"

Team.query.preload(:members).to_a
