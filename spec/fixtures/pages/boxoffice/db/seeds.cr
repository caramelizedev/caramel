module App
  # Schedules one show the first time it runs and prints its address; a second run finds it
  # and does nothing.
  def self.seed(db : DB::Database) : Nil
    return unless BoxOffice::Seating::Show.all.empty?

    show = BoxOffice::Seating::Show.schedule("The Tempest", Time.utc + 30.days,
      BoxOffice::Seating::Capacity.new(120))
    puts "Scheduled The Tempest with 120 seats at /shows/#{show.id.raw}."
  end
end
