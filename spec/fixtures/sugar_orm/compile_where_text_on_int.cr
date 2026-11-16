require "./schemas"

Team::Query.where(seats: containing("5")).to_a
