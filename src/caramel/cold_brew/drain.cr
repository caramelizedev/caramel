require "../../sugar_orm"
require "./queue"

module Caramel::ColdBrew
  DRAIN_LIMIT = 1000

  # Raised by `drain_queue!` when any job raised while draining.
  class DrainFailure < Exception
    record Failure, id : Int64, class_name : String, attempts : Int32, error : Exception

    getter failures : Array(Failure)

    def initialize(@failures : Array(Failure), queue : String)
      super(String.build do |io|
        io << @failures.size << " job(s) failed while draining queue " << queue << ':'
        @failures.each do |failure|
          io << "\n  " << failure.class_name << " #" << failure.id
          io << " (attempt " << failure.attempts << "): "
          io << failure.error.class << ": " << failure.error.message
        end
      end)
    end
  end

  # Raised when a drain ran DRAIN_LIMIT jobs and the queue still had due jobs.
  class DrainLimitExceeded < Exception
  end

  # Runs every due job of `queue` synchronously on `db`, including jobs that
  # jobs enqueue, until the queue is empty. `db` may be the connection of a
  # spec's transaction; each job then runs in a savepoint. A failed job
  # follows its retry policy and does not run again in the same drain; its
  # retry is due later, so a drain skips it unless `include_scheduled`.
  # Returns the number of runs; raises DrainFailure listing every failed run.
  def self.drain_queue!(db : SugarORM::Handle,
                        queue : String = "default",
                        include_scheduled : Bool = false) : Int32
    failures = [] of DrainFailure::Failure
    count = drain(db, queue, include_scheduled, failures)
    raise DrainFailure.new(failures, queue) unless failures.empty?
    count
  end

  # Like `drain_queue!` without raising for failed jobs; their rows keep
  # `last_error`.
  def self.drain_queue(db : SugarORM::Handle,
                       queue : String = "default",
                       include_scheduled : Bool = false) : Int32
    drain(db, queue, include_scheduled, [] of DrainFailure::Failure)
  end

  private def self.drain(db : SugarORM::Handle,
                         queue : String,
                         include_scheduled : Bool,
                         failures : Array(DrainFailure::Failure)) : Int32
    unless queue.matches?(QUEUE_NAME)
      raise ArgumentError.new("queue must be 1-63 characters from [a-z0-9_.:-]: #{queue.inspect}")
    end
    SugarORM::Repo.using(db) do
      count = 0
      failed = [] of Int64
      loop do
        if count == DRAIN_LIMIT
          break unless Queue.pending?(queue, include_scheduled, excluding: failed)
          raise DrainLimitExceeded.new(<<-TEXT)
            Draining queue #{queue} ran #{DRAIN_LIMIT} jobs and more are still due.
            Remediation: look for a job that enqueues itself on every run.
            TEXT
        end
        job = Queue.claim(queue, include_scheduled, excluding: failed) || break
        if error = Queue.run(job)
          failed << job.id
          failures << DrainFailure::Failure.new(job.id, job.class_name, job.attempts, error)
        end
        count += 1
      end
      count
    end
  end
end
