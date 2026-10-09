require "log"
require "../../sugar_orm"
require "./job"

module Caramel::ColdBrew
  # :nodoc:
  # The class names of rows that still wait to run or run again: not
  # locked, finished or failed. The predicate is the one of the partial index
  # `caramel_jobs_fetch`, so finished rows are never read.
  QUEUED_CLASS_NAMES = <<-SQL
    SELECT DISTINCT class_name FROM caramel_jobs
    WHERE locked_at IS NULL AND failed_at IS NULL AND finished_at IS NULL
    ORDER BY class_name
    SQL

  # The class names queued in `caramel_jobs` (not locked, finished or failed;
  # a crashed worker's lock is released by maintenance, and the row is listed
  # then) that this binary compiles neither as a job nor in a job's
  # `renamed_from`, sorted; empty when every queued job can run. A row queued under such a name
  # fails on its first run.
  # Read it through SugarORM::Repo's current connection before a deploy
  # takes the old binary away.
  def self.unknown_queued_class_names : Array(String)
    names = SugarORM.sql(QUEUED_CLASS_NAMES, as: {class_name: String})
    names.map(&.[:class_name]).reject { |name| Job.__cold_brew_known?(name) }
  end

  def self.unknown_queued_class_names(db : SugarORM::Handle) : Array(String)
    SugarORM::Repo.using(db) { unknown_queued_class_names }
  end

  # Logs a warning that names the stranded classes, and returns them. `work`
  # and `migrate` call it when they start, so the deploy's log shows it
  # before the old binary is gone. It stops nothing: a failed query is logged
  # by class and returns no names.
  def self.warn_unknown_queued(db : SugarORM::Handle) : Array(String)
    names = unknown_queued_class_names(db)
    return names if names.empty?

    Log.for("cold_brew").warn do
      "queued jobs name classes this binary does not compile: #{names.join(", ")}; " \
      "they fail on their first run. Restore the job, declare `renamed_from` on the " \
      "job that replaced it, or delete its rows from caramel_jobs"
    end
    names
  rescue error
    Log.for("cold_brew").warn { "could not check queued class names error_type=#{error.class}" }
    [] of String
  end
end
