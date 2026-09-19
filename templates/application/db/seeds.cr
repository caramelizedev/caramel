module App
  # Add deliberate seed operations here. This command never resets the database.
  def self.seed(db : DB::Database) : Nil
    puts "No seed data configured. Edit db/seeds.cr to add some."
  end
end
