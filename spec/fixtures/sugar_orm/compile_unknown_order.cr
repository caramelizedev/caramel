require "./schemas"

Team.query.order_by(:name, :desc).order_by(:popularity, :asc).to_a
