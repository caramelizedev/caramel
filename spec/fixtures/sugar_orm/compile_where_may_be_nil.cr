require "./schemas"

def teams_billed_to(email : String?)
  Team::Query.where(billing_email: email).to_a
end

teams_billed_to(ARGV.first?)
