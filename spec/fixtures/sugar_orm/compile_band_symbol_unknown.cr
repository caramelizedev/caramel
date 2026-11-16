require "./schemas"

Team::Query.where(seats: :lots).to_a
