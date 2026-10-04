module Caramel::Crema
  # Counts of durations in the buckets Prometheus and `caramel_metrics` share:
  # values up to each bound in `BOUNDS_MS`, then an overflow bucket.
  class Histogram
    BOUNDS_MS = {5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000}
    SIZE      = BOUNDS_MS.size + 1

    getter counts : StaticArray(Int64, 12)

    def initialize
      @counts = StaticArray(Int64, 12).new(0_i64)
    end

    def initialize(counts : Array(Int64))
      @counts = StaticArray(Int64, 12).new(0_i64)
      counts.first(SIZE).each_with_index { |count, index| @counts[index] = count }
    end

    # A value equal to a bound falls in that bound's bucket.
    def self.bucket(ms : Float64) : Int32
      BOUNDS_MS.each_with_index { |bound, index| return index if ms <= bound }
      BOUNDS_MS.size
    end

    def observe(ms : Float64) : Nil
      @counts[Histogram.bucket(ms)] += 1
    end

    def add(other : Histogram) : Nil
      SIZE.times { |index| @counts[index] += other.counts[index] }
    end

    def total : Int64
      @counts.sum
    end

    def to_a : Array(Int64)
      @counts.to_a
    end

    # Prometheus `histogram_quantile`: linear interpolation inside the bucket
    # holding the rank. The overflow bucket answers *max_ms*.
    def quantile(q : Float64, max_ms : Float64) : Float64
      count = total
      return 0.0 if count == 0

      rank = q * count
      seen = 0_i64
      BOUNDS_MS.each_with_index do |bound, index|
        inside = @counts[index]
        if seen + inside >= rank && inside > 0
          lower = index == 0 ? 0.0 : BOUNDS_MS[index - 1].to_f
          return lower + (bound - lower) * ((rank - seen) / inside)
        end
        seen += inside
      end
      max_ms
    end
  end

  # Durations aggregated by `{kind, key}`, guarded by a Mutex so a sink
  # can record while another fiber reads or swaps it.
  class Tally
    class Entry
      property count : Int64 = 0_i64
      property errors : Int64 = 0_i64
      property total_ms : Float64 = 0.0
      property max_ms : Float64 = 0.0
      property histogram : Histogram = Histogram.new
    end

    def initialize
      @entries = {} of {String, String} => Entry
      @lock = Mutex.new
    end

    def initialize(@entries : Hash({String, String}, Entry))
      @lock = Mutex.new
    end

    def record(kind : String, key : String, duration_ms : Float64, error : Bool) : Nil
      @lock.synchronize do
        entry = @entries[{kind, key}] ||= Entry.new
        entry.count += 1
        entry.errors += 1 if error
        entry.total_ms += duration_ms
        entry.max_ms = duration_ms if duration_ms > entry.max_ms
        entry.histogram.observe(duration_ms)
      end
    end

    # Yields a snapshot of every row; the Mutex is held, so do not block.
    def each(& : String, String, Entry ->) : Nil
      @lock.synchronize { @entries.each { |(kind, key), entry| yield kind, key, entry } }
    end

    def size : Int32
      @lock.synchronize { @entries.size }
    end

    def [](kind : String, key : String) : Entry?
      @lock.synchronize { @entries[{kind, key}]? }
    end

    # The rows recorded so far; this tally starts empty again.
    def swap : Tally
      @lock.synchronize do
        filled = Tally.new(@entries)
        @entries = {} of {String, String} => Entry
        filled
      end
    end
  end
end
