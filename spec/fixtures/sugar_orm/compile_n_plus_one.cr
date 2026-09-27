require "./schemas"

def show(team : Team)
  team.users.each do |user|
    puts user.email
  end
end

show(Team.query.find!(1))
