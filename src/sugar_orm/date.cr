require "json"

module SugarORM
  # A calendar day: a year, a month and a day, with no time of day and no zone,
  # so a day written in one zone is the same day read in another. The year runs
  # from 1 to 9999. Text is `YYYY-MM-DD`, which is how PostgreSQL prints a `date`
  # under every ISO `DateStyle`.
  #
  #     field due_on : SugarORM::Date, codec: SugarORM::DateCodec
  struct Date
    include Comparable(Date)

    ISO      = /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/
    MIN_YEAR =    1
    MAX_YEAR = 9999
    # The days from 0001-01-01 to 9999-12-31.
    MAX_SPAN_DAYS = 3_652_058

    getter year : Int32
    getter month : Int32
    getter day : Int32

    # Raises ArgumentError for a day that does not exist, such as 2026-02-30.
    def initialize(@year : Int32, @month : Int32, @day : Int32)
      unless self.class.calendar_day?(@year, @month, @day)
        raise ArgumentError.new("#{@year}-#{@month}-#{@day} is not a calendar day")
      end
    end

    def self.calendar_day?(year : Int32, month : Int32, day : Int32) : Bool
      return false unless (MIN_YEAR..MAX_YEAR).includes?(year) && (1..12).includes?(month)
      (1..Time.days_in_month(year, month)).includes?(day)
    end

    # The calendar day *time* shows in its own zone.
    def self.of(time : Time) : self
      new(time.year, time.month, time.day)
    end

    # Reads `YYYY-MM-DD` and nothing else; raises ArgumentError otherwise.
    def self.parse(text : String) : self
      parse?(text) || raise ArgumentError.new("#{text.inspect} is not a YYYY-MM-DD calendar day")
    end

    # The same as `parse`, or nil.
    def self.parse?(text : String) : self?
      match = ISO.match(text) || return
      year, month, day = match[1].to_i, match[2].to_i, match[3].to_i
      return unless calendar_day?(year, month, day)
      new(year, month, day)
    end

    def self.new(pull : JSON::PullParser) : self
      text = pull.read_string
      parse?(text) || pull.raise("expected a YYYY-MM-DD calendar day, not #{text.inspect}")
    end

    def <=>(other : Date) : Int32
      {@year, @month, @day} <=> {other.year, other.month, other.day}
    end

    # The day *days* after this one, or before it when negative; raises
    # ArgumentError outside year 1 to 9999.
    def plus_days(days : Int) : self
      raise out_of_range(days) if days.abs > MAX_SPAN_DAYS
      self.class.of(to_time + Time::Span.new(days: days.to_i))
    rescue ArgumentError
      raise out_of_range(days)
    end

    private def out_of_range(days : Int) : ArgumentError
      ArgumentError.new("#{self} plus #{days} days is outside year #{MIN_YEAR} to #{MAX_YEAR}")
    end

    # How many days after this one *other* falls; negative when it is earlier.
    def days_until(other : Date) : Int32
      (other.to_time - to_time).total_days.to_i
    end

    def day_of_week : Time::DayOfWeek
      to_time.day_of_week
    end

    # Midnight UTC of this day.
    def to_time : Time
      Time.utc(@year, @month, @day)
    end

    def to_s(io : IO) : Nil
      io << @year.to_s.rjust(4, '0') << '-'
      io << @month.to_s.rjust(2, '0') << '-'
      io << @day.to_s.rjust(2, '0')
    end

    def inspect(io : IO) : Nil
      io << "SugarORM::Date(" << self << ')'
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(to_s)
    end
  end

  # Stores a `SugarORM::Date` in a `date` column. A column of this codec takes a
  # Range in `where`, and orders by value.
  #
  #     field due_on : SugarORM::Date, codec: SugarORM::DateCodec
  module DateCodec
    ORDERABLE = true

    def self.sql_type : String
      "date"
    end

    def self.encode(value : Date) : String
      value.to_s
    end

    # Raises ArgumentError for `infinity`, a BC date, or any text but `YYYY-MM-DD`,
    # which a session whose `DateStyle` is not ISO prints for every date.
    def self.decode(text : String) : Date
      Date.parse?(text) || raise ArgumentError.new(
        "date column read as #{text.inspect}, which is not a YYYY-MM-DD day: " \
        "SugarORM::Date has no infinity or BC date, and the session's DateStyle must be ISO"
      )
    end
  end
end
