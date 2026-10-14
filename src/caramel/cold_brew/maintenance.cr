require "log"
require "wait_group"
require "../../sugar_orm"
require "../crema"
require "../cache"
require "./queue"

module Caramel::ColdBrew
  # The background housekeeping fiber: every `interval` it releases stale
  # job locks whose backend is gone, failing a job on its third release,
  # deletes expired cache rows, creates the daily job partitions
  # for today through today + 7 (UTC) and drops partitions that ended more
  # than `retention` ago and hold only finished or failed jobs.
  class Maintenance
    Log = ::Log.for("cold_brew.maintenance")

    DAYS_AHEAD = 7

    # Releases before maintenance fails a job as abandoned instead.
    RELEASE_LIMIT = 3
    ABANDONED     = Queue.describe(AbandonedJob.new(RELEASE_LIMIT))

    record Report, released : Int64, failed : Int64, expired : Int64, created : Int32,
      dropped : Int32

    RELEASE = <<-SQL
      UPDATE caramel_jobs
      SET locked_at = NULL, locked_by = NULL, releases = releases + 1,
          failed_at = CASE WHEN releases + 1 >= $2::int THEN now() END,
          last_error = CASE WHEN releases + 1 >= $2::int THEN $3::text ELSE last_error END
      WHERE locked_at < now() - make_interval(secs => $1)
        AND finished_at IS NULL AND failed_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM pg_stat_activity activity \
          WHERE activity.pid::text = caramel_jobs.locked_by)
      RETURNING id, queue, class_name, attempts, failed_at
      SQL
    RELEASED = {id: Int64, queue: String, class_name: String, attempts: Int32, failed_at: Time?}

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
    # locking backend no longer exists is released and counted; the release
    # that reaches RELEASE_LIMIT fails it with AbandonedJob instead and calls
    # the `on_failed` hooks, after that statement has committed.
    def run_once : Report
      SugarORM::Repo.using(@db) do
        rows = SugarORM.sql(RELEASE, @stale_after.total_seconds, RELEASE_LIMIT, ABANDONED,
          as: RELEASED)
        abandoned = rows.compact_map { |row| failure_of(row) }
        abandoned.each { |event| fail_abandoned(event) }
        expired = Cache.vacuum
        created = create_partitions
        dropped = drop_partitions
        released = (rows.size - abandoned.size).to_i64
        Report.new(released, abandoned.size.to_i64, expired, created, dropped)
      end
    end

    private def failure_of(row) : JobFailed?
      failed_at = row[:failed_at] || return
      JobFailed.new(
        id: row[:id], queue: row[:queue], class_name: row[:class_name],
        attempts: row[:attempts], failed_at: failed_at, error_class: AbandonedJob.name,
      )
    end

    # Mirrors the worker: report the error, then call the hooks.
    private def fail_abandoned(event : JobFailed) : Nil
      Crema.report(AbandonedJob.new(RELEASE_LIMIT), handled: false,
        source: "cold_brew.maintenance")
      ColdBrew.notify(event)
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
