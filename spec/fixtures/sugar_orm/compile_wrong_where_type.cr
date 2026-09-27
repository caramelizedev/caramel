require "./schemas"

Team::Query.where(seats: "many").to_a
