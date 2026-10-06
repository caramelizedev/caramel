require "./table"

module Caramel::Crema
  # What the `jobs` commands and the ops console ask Cold Brew's table. The
  # states mirror `JobStatus.state_for`.
  module Jobs
    UNFINISHED = "finished_at IS NULL AND failed_at IS NULL"
    WAITING    = "locked_at IS NULL AND #{UNFINISHED}"

    STATS = <<-SQL
      SELECT queue,
        count(*) FILTER (WHERE locked_at IS NOT NULL AND #{UNFINISHED})::text AS running,
        count(*) FILTER (WHERE #{WAITING} AND attempts > 0)::text AS retrying,
        count(*) FILTER (WHERE #{WAITING} AND attempts = 0 AND run_at <= now())::text AS queued,
        count(*) FILTER (WHERE #{WAITING} AND attempts = 0 AND run_at > now())::text AS scheduled,
        count(*) FILTER (WHERE failed_at IS NOT NULL)::text AS failed,
        count(*) FILTER (WHERE finished_at > now() - interval '1 hour')::text AS finished_1h,
        COALESCE(EXTRACT(EPOCH FROM now() - min(run_at) FILTER (
          WHERE #{WAITING} AND run_at <= now()))::bigint, 0)::text AS oldest_due_s
      FROM caramel_jobs
      GROUP BY queue
      ORDER BY queue
      SQL

    FAILED = <<-SQL
      SELECT class_name,
        COALESCE(substring(last_error FROM '^([A-Za-z_][A-Za-z0-9_:(), ]*?): '), '(unknown)')
          AS error_class,
        count(*)::text AS count,
        max(failed_at)::text AS last_failed_at,
        max(id)::text AS newest_id
      FROM caramel_jobs
      WHERE failed_at IS NOT NULL
      GROUP BY 1, 2
      ORDER BY max(failed_at) DESC
      LIMIT $1
      SQL

    # The one place a job's last error, a message that may hold secrets, is read; the
    # CLI prints it to the operator's terminal and nothing logs it.
    SHOW = <<-SQL
      SELECT id::text AS id, queue, class_name, priority::text AS priority,
        attempts::text AS attempts, run_at::text AS run_at, enqueued_at::text AS enqueued_at,
        COALESCE(locked_at::text, '') AS locked_at, COALESCE(finished_at::text, '') AS finished_at,
        COALESCE(failed_at::text, '') AS failed_at, COALESCE(last_error, '') AS last_error,
        COALESCE(context::text, '') AS context
      FROM caramel_jobs
      WHERE id = $1
      SQL

    # `attempts` stays, so a job past its retry rule gets exactly one more run.
    RETRY_ID = <<-SQL
      UPDATE caramel_jobs
      SET failed_at = NULL, locked_at = NULL, locked_by = NULL, run_at = now()
      WHERE failed_at IS NOT NULL AND id = $1
      RETURNING id::text AS id
      SQL

    RETRY_CLASS = <<-SQL
      UPDATE caramel_jobs
      SET failed_at = NULL, locked_at = NULL, locked_by = NULL, run_at = now()
      WHERE failed_at IS NOT NULL AND class_name = $1
      RETURNING id::text AS id
      SQL

    def self.stats(db : DB::Database? = nil) : Table
      Table.query(STATS, db: db)
    end

    def self.failed(limit : Int32 = 20, db : DB::Database? = nil) : Table
      Table.query(FAILED, [limit.to_i64] of SugarORM::Value, db)
    end

    def self.show(id : Int64, db : DB::Database? = nil) : Table
      Table.query(SHOW, [id] of SugarORM::Value, db)
    end

    # How many failed jobs were queued to run again.
    def self.retry_id(id : Int64, db : DB::Database? = nil) : Int32
      Table.query(RETRY_ID, [id] of SugarORM::Value, db).rows.size
    end

    def self.retry_class(name : String, db : DB::Database? = nil) : Int32
      Table.query(RETRY_CLASS, [name] of SugarORM::Value, db).rows.size
    end
  end
end
