require "./schemas"

Team.query.where(title: "Acme").to_a
