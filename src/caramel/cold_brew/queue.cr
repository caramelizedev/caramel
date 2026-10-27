require "../../sugar_orm"
require "../crema"
require "./job"
require "./hooks"

module Caramel::ColdBrew
  # A job row a worker has locked for one run. `attempts` includes this run;
  # `releases` counts earlier runs that maintenance released after their
  # process died.
  record Claim,
    id : Int64,
    enqueued_at : Time,
    class_name : String,
    payload : String,
    attempts : Int32,
    releases : Int32,
    queue : String,
    run_at : Time,
    context : String? do
    # The runs the retry rule counts: every run but the released ones.
    def counted_attempts : Int32
      attempts - releases
    end
  end

  # :nodoc:
  # The SQL shared by workers and drains. Every statement runs on
  # SugarORM::Repo's current connection.
  module Queue
    ERROR_LIMIT = 4000

    # The channel idle workers LISTEN on; the payload is the queue name. The
    # notify shares the insert's transaction, so it is delivered on commit.
    CHANNEL = "caramel_jobs"

    PUSH = <<-SQL
      WITH pushed AS (
        INSERT INTO caramel_jobs (queue, class_name, payload, priority, run_at, context)
        VALUES ($1, $2, $3::jsonb, $4, COALESCE($5::timestamptz, now()), $6::jsonb)
        RETURNING id, queue
      )
      SELECT pushed.id FROM pushed CROSS JOIN LATERAL pg_notify('#{CHANNEL}', pushed.queue) AS sent
      SQL

    # The claim sets locked_at and locked_by and counts the
    # attempt in the same statement that SKIP LOCKED selected the row with.
    # A drain passes the ids that already failed during it as $2.
    def self.claim_sql(due_only : Bool, drain : Bool) : String
      <<-SQL
        WITH selected AS (
          SELECT id, enqueued_at FROM caramel_jobs
          WHERE queue = $1#{" AND run_at <= now()" if due_only}#{" AND id <> ALL($2)" if drain}
            AND locked_at IS NULL AND failed_at IS NULL AND finished_at IS NULL
          ORDER BY priority DESC, id ASC
          LIMIT 1
          FOR UPDATE SKIP LOCKED
        )
        UPDATE caramel_jobs AS jobs
        SET locked_at = now(), locked_by = pg_backend_pid()::text, attempts = jobs.attempts + 1
        FROM selected
        WHERE jobs.id = selected.id AND jobs.enqueued_at = selected.enqueued_at
        RETURNING jobs.id, jobs.enqueued_at, jobs.class_name, \
                  jobs.payload::text AS payload, jobs.attempts, jobs.releases, \
                  jobs.queue, jobs.run_at, jobs.context::text AS context
        SQL
    end

    CLAIM     = claim_sql(due_only: true, drain: false)
    DRAIN_DUE = claim_sql(due_only: true, drain: true)
    DRAIN_ANY = claim_sql(due_only: false, drain: true)

    PENDING = <<-SQL
      SELECT EXISTS (
        SELECT 1 FROM caramel_jobs
        WHERE queue = $1 AND ($2 OR run_at <= now()) AND id <> ALL($3)
          AND locked_at IS NULL AND failed_at IS NULL AND finished_at IS NULL
      ) AS pending
      SQL

    FINISH = "UPDATE caramel_jobs SET finished_at = now() WHERE id = $1 AND enqueued_at = $2"

    RETRY = <<-SQL
      UPDATE caramel_jobs
      SET run_at = now() + make_interval(secs => $3), \
          locked_at = NULL, locked_by = NULL, last_error = $4
      WHERE id = $1 AND enqueued_at = $2
      RETURNING queue, run_at
      SQL

    FAIL = <<-SQL
      UPDATE caramel_jobs
      SET failed_at = now(), locked_at = NULL, locked_by = NULL, last_error = $3
      WHERE id = $1 AND enqueued_at = $2
      RETURNING queue, failed_at
      SQL

    # The last resort when a failure cannot be written: the row goes back to the queue.
    UNLOCK = <<-SQL
      UPDATE caramel_jobs SET locked_at = NULL, locked_by = NULL
      WHERE id = $1 AND enqueued_at = $2
      SQL

    CLAIMED = {
      id: Int64, enqueued_at: Time, class_name: String, payload: String, attempts: Int32,
      releases: Int32, queue: String, run_at: Time, context: String?,
    }

    # What a retry or a failure returns about the row it wrote.
    RESCHEDULED = {queue: String, run_at: Time}
    FAILED      = {queue: String, failed_at: Time}

    def self.push(queue : String,
                  class_name : String,
                  payload : String,
                  run_at : Time?,
                  priority : Int32) : Int64
      stored = ColdBrew.carry(payload)
      context = Crema.current?.try(&.propagation)
      Crema.measure(Crema::SpanKind::Enqueue, class_name, queue) do
        values = {queue, class_name, stored, priority, run_at, context}
        SugarORM.sql(PUSH, *values, as: {id: Int64}).first[:id]
      end
    end

    # The next due job of `queue`, locked for this connection's backend.
    def self.claim(queue : String) : Claim?
      SugarORM.sql(CLAIM, queue, as: CLAIMED).first?.try { |row| Claim.new(**row) }
    end

    # A drain's next job: never one that already failed during this drain.
    def self.claim(queue : String,
                   include_scheduled : Bool,
                   excluding failed : Array(Int64)) : Claim?
      sql = include_scheduled ? DRAIN_ANY : DRAIN_DUE
      SugarORM.sql(sql, queue, failed, as: CLAIMED).first?.try { |row| Claim.new(**row) }
    end

    def self.pending?(queue : String,
                      include_scheduled : Bool,
                      excluding failed : Array(Int64)) : Bool
      SugarORM.sql(PENDING, queue, include_scheduled, failed, as: {pending: Bool}).first[:pending]
    end

    # Runs `perform` and marks the job finished in one transaction, so the
    # job's writes and its completion commit together. On an exception the
    # transaction rolls back, the job is rescheduled or failed, and the
    # lifecycle hooks see the transition; the error is returned.
    def self.run(job : Claim) : Exception?
      Crema.job(job.id, job.class_name, job.queue, job.attempts, job.run_at, job.context) do
        run_traced(job)
      end
    end

    # The body of `run`, inside the job's trace.
    private def self.run_traced(job : Claim) : Exception?
      finished = false
      SugarORM::Repo.transaction do
        ColdBrew.carried(job.payload) { Job.__cold_brew_perform(job.class_name, job.payload) }
        finish(job)
        finished = true
      end
      # `Repo.rollback` in perform discarded the job's writes; the run still happened.
      finish(job) unless finished
      nil
    rescue error
      Crema.report(error, handled: false)
      if event = record_failure_surely(job, error)
        ColdBrew.notify(event)
      end
      error
    end

    # `record_failure`, with a second try describing only the class when the
    # first write raises, and an unlock when that raises too, so a message the
    # database rejects never leaves the row locked by a live backend.
    private def self.record_failure_surely(job : Claim, error : Exception) : Transition?
      record_failure(job, error)
    rescue
      begin
        record_failure(job, error, described: "#{error.class}: (message unavailable)")
      rescue exception
        SugarORM.sql_exec(UNLOCK, job.id, job.enqueued_at)
        Crema.report(exception, handled: true, source: "cold_brew.worker")
        nil
      end
    end

    # Reschedules or fails the job and returns the transition, which is
    # durable once this returns outside a transaction. Nil when the row is gone.
    # `described` replaces `describe(error)` as the stored `last_error`.
    def self.record_failure(job : Claim, error : Exception,
                            described : String = describe(error)) : Transition?
      rule = Retry.rule_for(Job.__cold_brew_lineage(job.class_name), error)
      counted = job.counted_attempts
      if error.is_a?(UnknownJob) || counted >= rule.attempts
        give_up(job, error, described)
      else
        reschedule(job, error, described, after: rule.delay(counted))
      end
    end

    private def self.reschedule(job : Claim, error : Exception, described : String,
                                after delay : Time::Span) : RetryScheduled?
      values = {job.id, job.enqueued_at, delay.total_seconds, described}
      row = SugarORM.sql(RETRY, *values, as: RESCHEDULED).first? || return
      RetryScheduled.new(
        id: job.id, queue: row[:queue], class_name: job.class_name,
        attempts: job.attempts, run_at: row[:run_at], error_class: error.class.name,
      )
    end

    private def self.give_up(job : Claim, error : Exception, described : String) : JobFailed?
      values = {job.id, job.enqueued_at, described}
      row = SugarORM.sql(FAIL, *values, as: FAILED).first? || return
      JobFailed.new(
        id: job.id, queue: row[:queue], class_name: job.class_name,
        attempts: job.attempts, failed_at: row[:failed_at], error_class: error.class.name,
      )
    end

    # The class, message and the first backtrace lines, within ERROR_LIMIT,
    # without the NUL bytes and invalid UTF-8 that PostgreSQL rejects in text.
    def self.describe(error : Exception) : String
      text = String.build do |io|
        io << error.class << ": " << error.message
        error.backtrace?.try(&.first(12).each { |line| io << "\n  " << line })
      end
      text = text[0, ERROR_LIMIT] if text.size > ERROR_LIMIT
      text.delete('\0').scrub
    end

    private def self.finish(job : Claim) : Nil
      SugarORM.sql_exec(FINISH, job.id, job.enqueued_at)
    end
  end
end
