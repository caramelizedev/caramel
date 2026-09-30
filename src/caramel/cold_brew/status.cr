require "json"
require "../../sugar_orm"

module Caramel::ColdBrew
  # Where a job stands, from its durable row.
  enum JobState
    # Waiting for a `run_at` in the future; it has not run.
    Scheduled
    # Due and waiting for a worker; it has not run.
    Queued
    # Locked by a worker. A lock whose process died stays until maintenance
    # releases it.
    Running
    # Ran and failed, and waits for its next attempt at `run_at`.
    Retrying
    Finished
    # Failed for good; it will not run again.
    Failed
  end

  # A job's state as its row records it. `attempts` counts its runs,
  # including one in progress. `error_class` names the exception of its most
  # recent failed run; the message and backtrace, which may hold secrets,
  # stay in the database.
  record JobStatus,
    id : Int64,
    queue : String,
    class_name : String,
    state : JobState,
    attempts : Int32,
    run_at : Time,
    enqueued_at : Time,
    locked_at : Time?,
    finished_at : Time?,
    failed_at : Time?,
    error_class : String? do
    include JSON::Serializable

    # Terminal states come first: a finished or failed row keeps its past.
    def self.state_for(*, finished : Bool, failed : Bool, locked : Bool,
                       attempts : Int32, due : Bool) : JobState
      return JobState::Finished if finished
      return JobState::Failed if failed
      return JobState::Running if locked
      return JobState::Retrying if attempts > 0

      due ? JobState::Queued : JobState::Scheduled
    end
  end

  # :nodoc:
  STATUS = <<-SQL
    SELECT id, queue, class_name, attempts, run_at, enqueued_at,
           locked_at, finished_at, failed_at,
           run_at <= now() AS due,
           substring(last_error FROM '^([A-Za-z_][A-Za-z0-9_:(), ]*?): ') AS error_class
    FROM caramel_jobs
    WHERE id = ANY($1)
    SQL

  # :nodoc:
  STATUS_ROW = {
    id: Int64, queue: String, class_name: String, attempts: Int32,
    run_at: Time, enqueued_at: Time,
    locked_at: Time?, finished_at: Time?, failed_at: Time?,
    due: Bool, error_class: String?,
  }

  # The status of the job `enqueue` returned `id` for, read through
  # SugarORM::Repo's current connection; nil once maintenance has dropped a
  # finished or failed job with its partition.
  def self.status(id : Int64) : JobStatus?
    statuses([id])[id]?
  end

  def self.status(db : SugarORM::Handle, id : Int64) : JobStatus?
    SugarORM::Repo.using(db) { status(id) }
  end

  # The status of each job in `ids` that still exists, in one query.
  def self.statuses(ids : Enumerable(Int64)) : Hash(Int64, JobStatus)
    ids = ids.to_a
    return {} of Int64 => JobStatus if ids.empty?

    rows = SugarORM.sql(STATUS, ids, as: STATUS_ROW)
    rows.to_h { |row| {row[:id], status_of(row)} }
  end

  def self.statuses(db : SugarORM::Handle,
                    ids : Enumerable(Int64)) : Hash(Int64, JobStatus)
    SugarORM::Repo.using(db) { statuses(ids) }
  end

  private def self.status_of(row) : JobStatus
    state = JobStatus.state_for(
      finished: !row[:finished_at].nil?,
      failed: !row[:failed_at].nil?,
      locked: !row[:locked_at].nil?,
      attempts: row[:attempts],
      due: row[:due],
    )
    JobStatus.new(
      id: row[:id],
      queue: row[:queue],
      class_name: row[:class_name],
      state: state,
      attempts: row[:attempts],
      run_at: row[:run_at],
      enqueued_at: row[:enqueued_at],
      locked_at: row[:locked_at],
      finished_at: row[:finished_at],
      failed_at: row[:failed_at],
      error_class: row[:error_class],
    )
  end
end
