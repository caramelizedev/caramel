require "log"
require "wait_group"
require "../../sugar_orm"

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
  # `pg_try_advisory_xact_lock(hashtext(name))` and the schedule's
  # `caramel_schedules` row, updated only once the period has elapsed.
  class Scheduler
    Log = ::Log.for("cold_brew.scheduler")

    LOCK = "SELECT pg_try_advisory_xact_lock(hashtext($1)) AS held"

    LEASE = <<-SQL
      INSERT INTO caramel_schedules AS schedules (name, last_run_at) VALUES ($1, now())
      ON CONFLICT (name) DO UPDATE SET last_run_at = now()
      WHERE schedules.last_run_at <= now() - make_interval(secs => $2)
      RETURNING name
      SQL

    REMAINING = <<-SQL
      SELECT EXTRACT(EPOCH FROM last_run_at + make_interval(secs => $2) \
        - clock_timestamp())::float8 AS seconds
      FROM caramel_schedules WHERE name = $1
      SQL

    def initialize(@schedules : Array(Schedule) = ColdBrew.schedules,
                   @db : DB::Database = SugarORM::Repo.database,
                   @retry : Time::Span = 1.minute)
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

    # Returns once no block is running.
    def stop : Nil
      @stopping.close
      @done.wait
    end

    # Runs the block when this process wins the lease for the current
    # period; false when another process holds it or the period has not
    # elapsed. The block's writes commit with the lease.
    def run_due(schedule : Schedule) : Bool
      ran = false
      SugarORM::Repo.using(@db) do
        SugarORM::Repo.transaction do
          held = SugarORM.sql(LOCK, schedule.name, as: {held: Bool}).first[:held]
          next unless held
          period = schedule.span.total_seconds
          next if SugarORM.sql(LEASE, schedule.name, period, as: {name: String}).empty?
          schedule.block.call
          ran = true
        end
      end
      ran
    end

    private def tick(schedule : Schedule) : Nil
      floor = {schedule.span, 1.second}.min
      until @stopping.closed?
        wait = begin
          run_due(schedule)
          remaining(schedule).clamp(floor, schedule.span)
        rescue error
          Log.error { "schedule=#{schedule.name} error_type=#{error.class}" }
          {schedule.span, @retry}.min
        end
        select
        when @stopping.receive?
        when timeout(wait)
        end
      end
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
