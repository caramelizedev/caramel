require "log"
require "wait_group"
require "../../sugar_orm"
require "./queue"

module Caramel::ColdBrew
  # A pool of fibers working one queue (RFC-0003 §2.2). Each fiber claims a
  # job with SKIP LOCKED and runs it on the connection that holds the claim;
  # an empty queue costs one 50 ms sleep.
  class Worker
    Log = ::Log.for("cold_brew.worker")

    getter queue : String
    getter concurrency : Int32

    def initialize(@queue : String = "default", @concurrency : Int32 = 16, @db : DB::Database = SugarORM::Repo.database, @idle : Time::Span = 50.milliseconds)
      raise ArgumentError.new("queue must be 1-63 characters from [a-z0-9_.:-]: #{@queue.inspect}") unless @queue.matches?(QUEUE_NAME)
      raise ArgumentError.new("concurrency must be at least 1") if @concurrency < 1
      @stopping = Channel(Nil).new
      @done = WaitGroup.new
      @started = false
    end

    def start : self
      raise ArgumentError.new("#{self} was already started") if @started
      @started = true
      @done.add(@concurrency)
      @concurrency.times { |index| spawn(name: "cold_brew:#{@queue}:#{index}") { run } }
      self
    end

    # Stops fetching and returns once every in-flight job has finished.
    def stop : Nil
      @stopping.close
      @done.wait if @started
    end

    def to_s(io : IO) : Nil
      io << "Caramel::ColdBrew::Worker(" << @queue << ", " << @concurrency << ')'
    end

    private def run : Nil
      until @stopping.closed?
        begin
          worked = @db.using_connection { |connection| SugarORM::Repo.bind(connection) { work } }
          pause(@idle) unless worked
        rescue error
          # The message may carry connection details; the class is enough to act on.
          Log.error { "queue=#{@queue} error_type=#{error.class}" }
          pause(1.second)
        end
      end
    ensure
      @done.done
    end

    private def work : Bool
      job = Queue.claim(@queue) || return false
      if error = Queue.run(job)
        Log.warn { "queue=#{@queue} job=#{job.id} class=#{job.class_name} attempt=#{job.attempts} error_type=#{error.class}" }
      end
      true
    end

    private def pause(span : Time::Span) : Nil
      select
      when @stopping.receive?
      when timeout(span)
      end
    end
  end
end
