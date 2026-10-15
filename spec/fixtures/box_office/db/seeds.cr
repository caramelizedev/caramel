module App
  # Schedules one show the first time it runs; a second run finds it and does nothing.
  def self.seed(db : DB::Database) : Nil
    return unless App::BoxOffice::Seating::Show.all.empty?

    App::BoxOffice::Seating::Show.schedule("The Tempest", Time.utc + 30.days,
      App::BoxOffice::Seating::Capacity.new(120))
    puts "Scheduled The Tempest with 120 seats."
  end
end
