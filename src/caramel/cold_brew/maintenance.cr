require "log"
require "wait_group"
require "../../sugar_orm"
require "../crema"
require "../cache"

module Caramel::ColdBrew
  # The background housekeeping fiber: every `interval` it releases stale
  # job locks, deletes expired cache rows, creates the daily job partitions
  # for today through today + 7 (UTC) and drops partitions that ended more
  # than `retention` ago and hold only finished or failed jobs.
  class Maintenance
    Log = ::Log.for("cold_brew.maintenance")

    DAYS_AHEAD = 7

    record Report, released : Int64, expired : Int64, created : Int32, dropped : Int32

    RELEASE = <<-SQL
      UPDATE caramel_jobs SET locked_at = NULL, locked_by = NULL
      WHERE locked_at < now() - make_interval(secs => $1)
        AND finished_at IS NULL AND failed_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM pg_stat_activity activity \
          WHERE activity.pid::text = caramel_jobs.locked_by)
      SQL

    CREATE_PARTITIONS = "SELECT caramel_jobs_create_partitions(" \
                        "(now() AT TIME ZONE 'UTC')::date, $1) AS created"
    DROP_PARTITIONS = "SELECT caramel_jobs_drop_partitions(" \
                      "make_interval(secs => $1)) AS dropped"

    def initialize(@db : DB::Database = SugarORM::Repo.database, @retention : Time::Span = 7.days,
                   @stale_after : Time::Span = 15.minutes, @interval : Time::Span = 60.seconds)
      # The partition function refuses shorter windows; fail at construction.
      raise ArgumentError.new("retention must be at least one day") if @retention < 1.day
      @stopping = Channel(Nil).new
      @done = WaitGroup.new
    end

    def start : self
      @done.add(1)
      spawn(name: "cold_brew:maintenance") do
        until @stopping.closed?
          begin
            run_once
          rescue error
            Crema.report(error, handled: false, source: "cold_brew.maintenance")
          end
          select
          when @stopping.receive?
          when timeout(@interval)
          end
        end
      ensure
        @done.done
      end
      self
    end

    def stop : Nil
      @stopping.close
      @done.wait
    end

    # One pass. A job whose lock is older than `stale_after` and whose
    # locking backend no longer exists runs again.
    def run_once : Report
      SugarORM::Repo.using(@db) do
        released = SugarORM.sql_exec(RELEASE, @stale_after.total_seconds)
        expired = Cache.vacuum
        created = create_partitions
        dropped = drop_partitions
        Report.new(released, expired, created, dropped)
      end
    end

    private def create_partitions : Int32
      rows = SugarORM.sql(CREATE_PARTITIONS, DAYS_AHEAD, as: {created: Int32})
      rows.first[:created]
    end

    private def drop_partitions : Int32
      rows = SugarORM.sql(DROP_PARTITIONS, @retention.total_seconds, as: {dropped: Int32})
      rows.first[:dropped]
    end
  end
end
