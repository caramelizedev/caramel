require "../../sugar_orm"
require "./job"
require "./hooks"

module Caramel::ColdBrew
  # A job row a worker has locked for one run; `attempts` includes this run.
  record Claim, id : Int64, enqueued_at : Time, class_name : String, payload : String, attempts : Int32

  # :nodoc:
  # The SQL shared by workers and drains. Every statement runs on
  # SugarORM::Repo's current connection.
  module Queue
    ERROR_LIMIT = 4000

    PUSH = <<-SQL
      INSERT INTO caramel_jobs (queue, class_name, payload, priority, run_at)
      VALUES ($1, $2, $3::jsonb, $4, COALESCE($5::timestamptz, now()))
      RETURNING id
      SQL

    # RFC-0003 §2.2: the claim sets locked_at and locked_by and counts the
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
        RETURNING jobs.id, jobs.enqueued_at, jobs.class_name, jobs.payload::text AS payload, jobs.attempts
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
      SET run_at = now() + make_interval(secs => $3), locked_at = NULL, locked_by = NULL, last_error = $4
      WHERE id = $1 AND enqueued_at = $2
      RETURNING queue, run_at
      SQL

    FAIL = <<-SQL
      UPDATE caramel_jobs
      SET failed_at = now(), locked_at = NULL, locked_by = NULL, last_error = $3
      WHERE id = $1 AND enqueued_at = $2
      RETURNING queue, failed_at
      SQL

    CLAIMED = {id: Int64, enqueued_at: Time, class_name: String, payload: String, attempts: Int32}

    def self.push(queue : String, class_name : String, payload : String, run_at : Time?, priority : Int32) : Int64
      SugarORM.sql(PUSH, queue, class_name, payload, priority, run_at, as: {id: Int64}).first[:id]
    end

    # The next due job of `queue`, locked for this connection's backend.
    def self.claim(queue : String) : Claim?
      SugarORM.sql(CLAIM, queue, as: CLAIMED).first?.try { |row| Claim.new(**row) }
    end

    # A drain's next job: never one that already failed during this drain.
    def self.claim(queue : String, include_scheduled : Bool, excluding failed : Array(Int64)) : Claim?
      SugarORM.sql(include_scheduled ? DRAIN_ANY : DRAIN_DUE, queue, failed, as: CLAIMED).first?.try { |row| Claim.new(**row) }
    end

    def self.pending?(queue : String, include_scheduled : Bool, excluding failed : Array(Int64)) : Bool
      SugarORM.sql(PENDING, queue, include_scheduled, failed, as: {pending: Bool}).first[:pending]
    end

    # Runs `perform` and marks the job finished in one transaction, so the
    # job's writes and its completion commit together. On an exception the
    # transaction rolls back, the job is rescheduled or failed, and the
    # lifecycle hooks see the transition; the error is returned.
    def self.run(job : Claim) : Exception?
      finished = false
      SugarORM::Repo.transaction do
        Job.__cold_brew_perform(job.class_name, job.payload)
        finish(job)
        finished = true
      end
      # `Repo.rollback` in perform discarded the job's writes; the run still happened.
      finish(job) unless finished
      nil
    rescue error
      if event = record_failure(job, error)
        ColdBrew.notify(event)
      end
      error
    end

    # Reschedules or fails the job and returns the transition, which is
    # durable once this returns outside a transaction. Nil when the row is gone.
    def self.record_failure(job : Claim, error : Exception) : (RetryScheduled | JobFailed)?
      message = describe(error)
      rule = Retry.rule_for(Job.__cold_brew_lineage(job.class_name), error)
      if error.is_a?(UnknownJob) || job.attempts >= rule.attempts
        SugarORM.sql(FAIL, job.id, job.enqueued_at, message, as: {queue: String, failed_at: Time}).first?.try do |row|
          JobFailed.new(job.id, row[:queue], job.class_name, job.attempts, row[:failed_at], error.class.name)
        end
      else
        delay = rule.delay(job.attempts).total_seconds
        SugarORM.sql(RETRY, job.id, job.enqueued_at, delay, message, as: {queue: String, run_at: Time}).first?.try do |row|
          RetryScheduled.new(job.id, row[:queue], job.class_name, job.attempts, row[:run_at], error.class.name)
        end
      end
    end

    # The class, message and the first backtrace lines, within ERROR_LIMIT.
    def self.describe(error : Exception) : String
      text = String.build do |io|
        io << error.class << ": " << error.message
        error.backtrace?.try(&.first(12).each { |line| io << "\n  " << line })
      end
      text.size > ERROR_LIMIT ? text[0, ERROR_LIMIT] : text
    end

    private def self.finish(job : Claim) : Nil
      SugarORM.sql_exec(FINISH, job.id, job.enqueued_at)
    end
  end
end
