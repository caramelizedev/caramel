require "./schemas"

Team::Query.where_null(:name).to_a
