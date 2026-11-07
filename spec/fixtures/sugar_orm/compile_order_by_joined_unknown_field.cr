require "./schemas"

User.query.joins(:team).order_by_joined(:team, :popularity).to_a
