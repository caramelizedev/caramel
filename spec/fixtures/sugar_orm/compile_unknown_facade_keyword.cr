require "./schemas"

Team.query.find!(1).update(name: "Renamed")
