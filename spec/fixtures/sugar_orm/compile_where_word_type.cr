require "./schemas"

Team::Query.where(archived: over(true)).to_a
