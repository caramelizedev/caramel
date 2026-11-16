require "./schemas"

Team::Query.where(name: not(nil)).to_a
