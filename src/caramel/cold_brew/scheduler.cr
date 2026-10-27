require "log"
require "wait_group"
require "../../sugar_orm"
require "../crema"

module Caramel::ColdBrew
  record Schedule, span : Time::Span, name : String, block : Proc(Nil)

  @@schedules = [] of Schedule

  # Declares a recurring task, run by `serve`'s scheduler. Every process
  # ticks, but a database lease lets only one of them run the block per
  # period, inside the lease's transaction:
  #
  #     Caramel::ColdBrew.every(1.hour, "nightly-cleanup") { CleanupJob.enqueue }
  def self.every(span : Time::Span, name : String, &block : ->) : Nil
    if span < 1.second
      raise ArgumentError.new("every needs a span of at least 1 second, got #{span}")
    end
    raise ArgumentError.new("every needs a schedule name") if name.blank?
    if @@schedules.any? { |schedule| schedule.name == name }
      raise ArgumentError.new("A schedule named #{name.inspect} already exists")
    end
    @@schedules << Schedule.new(span, name, block)
  end

  def self.schedules : Array(Schedule)
    @@schedules
  end

  # One fiber per schedule. Each tick takes the lease: a
  # `pg_try_advisory_xact_lock(LOCK_NAMESPACE, hashtext(name))` and the schedule's
  # `caramel_schedules` row, updated only once the period has elapsed. A block that
  # raises rolls the lease back, but its attempt is recorded, so its period counts as
  # run and the next attempt comes after the span. A tick holds one of SCHEDULE_SLOTS
  # while it does, so the blocks never take more of the pool.
  class Scheduler
    Log = ::Log.for("cold_brew.scheduler")

    # Caramel's advisory-lock namespace ("cara" in ASCII): the first key of every
    # two-key lock Caramel takes, so a lease never meets an application's own
    # `pg_advisory_lock(n)` in the one-key space.
    LOCK_NAMESPACE = 0x6361_7261

    LOCK = "SELECT pg_try_advisory_xact_lock($1, hashtext($2)) AS held"

    LEASE = <<-SQL
      INSERT INTO caramel_schedules AS schedules (name, last_run_at) VALUES ($1, now())
      ON CONFLICT (name) DO UPDATE SET last_run_at = now()
      WHERE schedules.last_run_at <= now() - make_interval(secs => $2)
      RETURNING name
      SQL

    FAILED = <<-SQL
      INSERT INTO caramel_schedules (name, last_run_at) VALUES ($1, now())
      ON CONFLICT (name) DO UPDATE SET last_run_at = now()
      RETURNING name
      SQL

    REMAINING = <<-SQL
      SELECT EXTRACT(EPOCH FROM last_run_at + make_interval(secs => $2) \
        - clock_timestamp())::float8 AS seconds
      FROM caramel_schedules WHERE name = $1
      SQL

    def initialize(@schedules : Array(Schedule) = ColdBrew.schedules,
                   @db : DB::Database = SugarORM::Repo.database,
                   @retry : Time::Span = 1.minute,
                   slots : Int32 = SCHEDULE_SLOTS)
      @slots = Channel(Nil).new(slots)
      @stopping = Channel(Nil).new
      @done = WaitGroup.new
    end

    def start : self
      @done.add(@schedules.size)
      @schedules.each do |schedule|
        spawn(name: "cold_brew:every:#{schedule.name}") do
          tick(schedule)
        ensure
          @done.done
        end
      end
      self
    end

    # Starts no more blocks; returns at once.
    def halt : Nil
      @stopping.close
    end

    # Returns once no block is running.
    def stop : Nil
      @stopping.close
      @done.wait
    end

    # Runs the block when this process wins the lease for the current
    # period; false when another process holds it or the period has not
    # elapsed. The block's writes commit with the lease. It first waits for a
    # schedule slot, and returns false when the scheduler stops while it waits.
    def run_due(schedule : Schedule) : Bool
      with_slot { run_leased(schedule) }
    end

    private def with_slot(& : -> Bool) : Bool
      return false if @stopping.closed?
      select
      when @slots.send(nil)
        begin
          yield
        ensure
          @slots.receive
        end
      when @stopping.receive?
        false
      end
    end

    private def run_leased(schedule : Schedule) : Bool
      ran = false
      started = false
      SugarORM::Repo.using(@db) do
        SugarORM::Repo.transaction do
          held = SugarORM.sql(LOCK, LOCK_NAMESPACE, schedule.name, as: {held: Bool}).first[:held]
          next unless held
          period = schedule.span.total_seconds
          next if SugarORM.sql(LEASE, schedule.name, period, as: {name: String}).empty?
          started = true
          Crema.schedule(schedule.name) { schedule.block.call }
          ran = true
        end
      rescue error
        record_failure(schedule) if started
        raise error
      end
      ran
    end

    # The lease rolled back with the block; this autocommit upsert still counts the
    # period as run. When recording itself fails, the block's error is the one to
    # propagate, so this one is only logged.
    private def record_failure(schedule : Schedule) : Nil
      SugarORM::Repo.using(@db) do
        SugarORM.sql(FAILED, schedule.name, as: {name: String})
      end
    rescue error
      Log.warn do
        "schedule=#{schedule.name} could not record a failed run error_type=#{error.class}"
      end
    end

    private def tick(schedule : Schedule) : Nil
      floor = {schedule.span, 1.second}.min
      until @stopping.closed?
        wait = begin
          run_due(schedule)
          remaining(schedule).clamp(floor, schedule.span)
        rescue error
          # A block's error was reported by its trace; anything else is reported here.
          unless Crema.reported?(error)
            Crema.report(error, handled: false, source: "cold_brew.scheduler")
          end
          after_error(schedule, floor)
        end
        select
        when @stopping.receive?
        when timeout(wait)
        end
      end
    end

    # A failed block's period counts as run, so the next attempt waits like a
    # successful one; `@retry` only covers a database that cannot say how long.
    private def after_error(schedule : Schedule, floor : Time::Span) : Time::Span
      remaining(schedule).clamp(floor, schedule.span)
    rescue
      {schedule.span, @retry}.min
    end

    private def remaining(schedule : Schedule) : Time::Span
      SugarORM::Repo.using(@db) do
        period = schedule.span.total_seconds
        rows = SugarORM.sql(REMAINING, schedule.name, period, as: {seconds: Float64})
        seconds = rows.first?.try(&.[:seconds])
        seconds ? seconds.seconds : Time::Span.zero
      end
    end
  end
end
