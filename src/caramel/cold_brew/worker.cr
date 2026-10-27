require "log"
require "wait_group"
require "../../sugar_orm"
require "../crema"
require "./queue"

module Caramel::ColdBrew
  # A pool of fibers working one queue. Each fiber claims a
  # job with SKIP LOCKED and runs it on the connection that holds the claim.
  # An idle fiber waits `idle` (default 1 s) between claims, and wakes early
  # when `Queue::CHANNEL` carries its queue's name: every enqueue notifies it
  # on commit, through the process's `ColdBrew.broker`. Without a broker, or
  # for scheduled runs, retries and a notification lost while the broker
  # reconnects, the poll is what runs the job.
  class Worker
    Log = ::Log.for("cold_brew.worker")

    getter queue : String
    getter concurrency : Int32

    def initialize(@queue : String = "default",
                   @concurrency : Int32 = 16,
                   @db : DB::Database = SugarORM::Repo.database,
                   @idle : Time::Span = 1.second)
      unless @queue.matches?(QUEUE_NAME)
        raise ArgumentError.new("queue must be 1-63 characters from [a-z0-9_.:-]: " \
                                "#{@queue.inspect}")
      end
      raise ArgumentError.new("concurrency must be at least 1") if @concurrency < 1
      @stopping = Channel(Nil).new
      @done = WaitGroup.new
      @running = Atomic(Int32).new(0)
      @started = false
      # One token per fiber: a burst of notifications wakes every idle fiber once.
      @wake = Channel(Nil).new(@concurrency)
      @notifications = Channel(String).new
    end

    def start : self
      raise ArgumentError.new("#{self} was already started") if @started
      @started = true
      @done.add(@concurrency)
      @concurrency.times { |index| spawn(name: "cold_brew:#{@queue}:#{index}") { run } }
      spawn(name: "cold_brew:#{@queue}:wake") { listen }
      self
    end

    # Stops claiming jobs; returns at once.
    def halt : Nil
      @stopping.close
      @notifications.close
    end

    # How many jobs this worker is running now.
    def running : Int32
      @running.get
    end

    # Stops fetching and returns once every in-flight job has finished.
    def stop : Nil
      halt
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
          # Crema keeps the redacted message in memory; logs carry the class.
          Crema.report(error, handled: false, source: "cold_brew.worker")
          pause(1.second)
        end
      end
    ensure
      @done.done
    end

    private def work : Bool
      job = Queue.claim(@queue) || return false
      @running.add(1)
      begin
        Queue.run(job)
      ensure
        @running.sub(1)
      end
      true
    end

    private def pause(span : Time::Span) : Nil
      select
      when @stopping.receive?
      when @wake.receive
      when timeout(span)
      end
    end

    # Forwards this queue's notifications to `@wake`; the subscription ends
    # with this fiber. Without a broker the fibers poll.
    private def listen : Nil
      broker = ColdBrew.broker? || return
      broker.subscribe(Queue::CHANNEL, @notifications)
      while payload = @notifications.receive?
        next unless payload == @queue
        select
        when @wake.send(nil)
        else
        end
      end
    rescue error
      Crema.report(error, handled: true, source: "cold_brew.worker")
    ensure
      ColdBrew.broker?.try(&.unsubscribe(Queue::CHANNEL, @notifications))
    end
  end
end
