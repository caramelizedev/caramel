require "../../sugar_orm"
require "./runtime"
require "./tally"

module Caramel::Crema
  # The opt-in recorder (ADR 0028): `require "caramel/crema/recorder"` makes the
  # process keep per-minute counts and latency histograms in `caramel_metrics`, for
  # `APP insights` and the console. It records aggregates only: route templates,
  # job classes, schedule names, parameterized SQL and `METHOD host`. No message,
  # backtrace, trace or span leaves memory. A failed write loses that batch and
  # never touches the work it measured.
  class Recorder < Sink
    class_property retention : Time::Span = 7.days
    class_property flush_interval : Time::Span = 15.seconds

    # Distinct keys of one kind per flush; the rest fold into `(other)`.
    MAX_KEYS = 500
    # An SQL key is the statement with whitespace runs collapsed, cut here.
    MAX_SQL_KEY = 500
    OTHER       = "(other)"
    PRUNE_EVERY = 1.hour
    STOP_WAIT   = 5.seconds

    UPSERT = <<-SQL
      INSERT INTO caramel_metrics AS m
        (bucket, kind, key, count, errors, total_ms, max_ms, histogram)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      ON CONFLICT (bucket, kind, key) DO UPDATE SET
        count = m.count + EXCLUDED.count,
        errors = m.errors + EXCLUDED.errors,
        total_ms = m.total_ms + EXCLUDED.total_ms,
        max_ms = GREATEST(m.max_ms, EXCLUDED.max_ms),
        histogram = ARRAY(
          SELECT h.a + h.b
          FROM unnest(m.histogram, EXCLUDED.histogram) WITH ORDINALITY AS h(a, b, i)
          ORDER BY h.i
        )
      SQL

    PRUNE = "DELETE FROM caramel_metrics WHERE bucket < now() - make_interval(secs => $1)"

    def initialize(@database : DB::Database)
      @lock = Mutex.new
      @window = Tally.new
      @keys = {} of String => Set(String)
      @keys_bucket = Time.utc.at_beginning_of_minute
      @stopping = Channel(Nil).new
      @done = Channel(Nil).new
      @last_prune = Time.instant - PRUNE_EVERY
    end

    def name : String
      "recorder"
    end

    # SQL and outbound aggregates come from spans, which MAX_SPANS bounds.
    def records?(trace : Trace) : Bool
      true
    end

    def finished(trace : Trace) : Nil
      failed = trace.outcome == "error"
      duration = Trace.ms(trace.duration)
      @lock.synchronize do
        add(trace.kind.wire, trace.name, duration, failed)
        trace.spans.each { |span| add_span(span) }
      end
    end

    # Writes the window recorded so far into the minute bucket of *at*,
    # synchronously. The loop, the stopper and specs use it.
    def flush(at : Time = Time.utc) : Nil
      bucket = at.at_beginning_of_minute
      window = @lock.synchronize do
        unless @keys_bucket == bucket
          @keys.clear
          @keys_bucket = bucket
        end
        @window.swap
      end
      rows = window.size
      return if rows == 0

      write(window, bucket)
    rescue error
      LOG.warn { "recorder flush failed error_type=#{error.class}" }
      Crema.drop("recorder", (rows || 0).to_i64)
    end

    def start : self
      spawn(name: "crema:recorder") { run }
      self
    end

    # Stops the loop, then writes what remains. A loop that does not finish within
    # `STOP_WAIT` is left behind and the final write is skipped. Safe to call twice.
    def stop : Nil
      @stopping.close unless @stopping.closed?
      select
      when @done.receive?
        flush
      when timeout(STOP_WAIT)
        LOG.warn { "recorder did not stop within #{STOP_WAIT.total_seconds.to_i}s" }
      end
    end

    private def run : Nil
      loop do
        select
        when @stopping.receive?
          break
        when timeout(self.class.flush_interval)
          flush
          prune if Time.instant - @last_prune >= PRUNE_EVERY
        end
      end
    ensure
      @done.close
    end

    private def add_span(span : Span) : Nil
      failed = !span.error_class.nil?
      if span.kind.sql?
        add("sql", sql_key(span.detail || span.name), Trace.ms(span.duration), failed)
      elsif span.kind.http?
        add("outbound", span.name, Trace.ms(span.duration), failed)
      end
    end

    private def add(kind : String, key : String, duration : Float64, failed : Bool) : Nil
      key = key.delete('\0')
      known = (@keys[kind] ||= Set(String).new)
      known << key if known.size < MAX_KEYS || known.includes?(key)
      @window.record(kind, known.includes?(key) ? key : OTHER, duration, failed)
    end

    # The statement as one aggregate key: literals, numbers and `IN` lists become
    # `?`, whitespace collapses, NUL bytes go, and the result is cut to `MAX_SQL_KEY`.
    def self.sql_key(sql : String) : String
      sql.delete('\0')
        .gsub(/'(?:[^']|'')*'/, "?")
        .gsub(/(?<![\w$])\d+(?!\w)/, "?")
        .gsub(/\bIN\s*\(\s*(?:\?|\$\d+)(?:\s*,\s*(?:\?|\$\d+))*\s*\)/i, "IN (?)")
        .gsub(/\s+/, " ").strip
        .byte_slice(0, MAX_SQL_KEY).scrub
    end

    private def sql_key(sql : String) : String
      self.class.sql_key(sql)
    end

    private def write(window : Tally, bucket : Time) : Nil
      SugarORM::Repo.using(@database) do
        SugarORM::Repo.transaction do
          window.each do |kind, key, entry|
            values = [bucket, kind, key, entry.count, entry.errors, entry.total_ms, entry.max_ms,
                      entry.histogram.to_a] of SugarORM::Value
            SugarORM::Repo.exec(UPSERT, values)
          end
        end
      end
    end

    private def prune : Nil
      @last_prune = Time.instant
      seconds = self.class.retention.total_seconds
      SugarORM::Repo.using(@database) { SugarORM::Repo.exec(PRUNE, [seconds] of SugarORM::Value) }
    rescue error
      LOG.warn { "recorder prune failed error_type=#{error.class}" }
    end
  end

  on_start do |runtime|
    database = runtime.database
    if database
      recorder = Recorder.new(database).start
      subscribe(recorder)
      -> do
        unsubscribe(recorder)
        recorder.stop
        nil
      end
    end
  end
end

require "./recorder/insights"
