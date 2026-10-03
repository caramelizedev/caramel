require "./compile_usage_examples"

# The un-preloaded access must not compile.
def usage_n_plus_one(team_id : Int64)
  Team.query.find!(team_id).users.each { |user| puts user.email }
end

usage_n_plus_one(1_i64)
