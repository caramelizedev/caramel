require "./schemas"

def teams_not_billed_to(email : String?)
  Team::Query.where(billing_email: not(email)).to_a
end

teams_not_billed_to(ARGV.first?)
