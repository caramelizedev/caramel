require "./compile_rfc_examples"

# RFC-0002 §2.2: the un-preloaded access must not compile.
def rfc_n_plus_one(team_id : Int64)
  Team.query.find!(team_id).users.each { |user| puts user.email }
end

rfc_n_plus_one(1_i64)
