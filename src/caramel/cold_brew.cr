require "wait_group"
require "./database"
require "../sugar_orm"
require "./cache"
require "./cold_brew/migrations"
require "./cold_brew/job"
require "./cold_brew/queue"
require "./cold_brew/status"
require "./cold_brew/worker"
require "./cold_brew/drain"
require "./cold_brew/broker"
require "./cold_brew/maintenance"
require "./cold_brew/scheduler"

# Caramel Cold Brew: background jobs, recurring tasks, PubSub
# and the cache, all in PostgreSQL.
module Caramel::ColdBrew
  CHANNEL_NAME  = /\A[a-z0-9_.:-]{1,63}\z/
  PAYLOAD_LIMIT = 8000
  NO_BROKER     = "Caramel::ColdBrew has no PubSub broker in this process.\n" \
                  "Remediation: `serve` starts one with Caramel::ColdBrew.start; " \
                  "elsewhere set Caramel::ColdBrew.broker = " \
                  "Caramel::ColdBrew::Broker.new(database_url)."

  class ConfigurationError < Exception
  end

  @@broker : Broker? = nil

  def self.broker=(broker : Broker?) : Broker?
    @@broker = broker
  end

  def self.broker? : Broker?
    @@broker
  end

  def self.broker : Broker
    @@broker || raise ConfigurationError.new(NO_BROKER)
  end

  # Sends `payload` to `channel` with pg_notify on SugarORM::Repo's current
  # connection: inside `Repo.transaction` it is delivered only on commit.
  def self.publish(channel : String, payload : String) : Nil
    validate_channel!(channel)
    if payload.bytesize > PAYLOAD_LIMIT
      message = "PubSub payloads are limited to #{PAYLOAD_LIMIT} bytes, " \
                "got #{payload.bytesize}; publish an id and read the record instead"
      raise ArgumentError.new(message)
    end
    SugarORM.sql_exec("SELECT pg_notify($1, $2)", channel(channel), payload)
    nil
  end

  # Delivers every payload published to `channel` into `subscriber` until
  # `unsubscribe`, the channel closes, or the subscribing fiber ends.
  def self.subscribe(channel : String, subscriber : Channel(String)) : Nil
    validate_channel!(channel)
    broker.subscribe(channel(channel), subscriber)
  end

  def self.unsubscribe(channel : String, subscriber : Channel(String)) : Nil
    validate_channel!(channel)
    broker?.try(&.unsubscribe(channel(channel), subscriber))
  end

  # Subscribes a new channel for the block and unsubscribes afterwards.
  def self.subscribe(channel : String, & : Channel(String) -> _)
    subscriber = Channel(String).new
    subscribe(channel, subscriber)
    begin
      yield subscriber
    ensure
      unsubscribe(channel, subscriber)
    end
  end

  def self.validate_channel!(name : String) : Nil
    unless name.matches?(CHANNEL_NAME)
      message = "PubSub channel names are 1-63 characters from [a-z0-9_.:-], " \
                "got #{name.inspect}"
      raise ArgumentError.new(message)
    end
  end

  # The PubSub channel *name* stands for. `caramel/tenancy` prefixes the
  # bound tenant.
  def self.channel(name : String) : String
    name
  end

  # The payload a job is stored with. `caramel/tenancy` adds the tenant
  # it was enqueued in.
  def self.carry(payload : String) : String
    payload
  end

  # Runs a claimed job's perform. `caramel/tenancy` binds the tenant its
  # payload carries.
  def self.carried(payload : String, &) : Nil
    yield
  end

  # What `serve` runs beside the HTTP server, on a pool of its own so jobs
  # never wait for request connections.
  class Service
    getter workers : Array(Worker)
    getter broker : Broker

    # The pool Cold Brew's workers and maintenance use.
    def database : DB::Database
      @db
    end

    def initialize(@db : DB::Database,
                   @workers : Array(Worker),
                   @maintenance : Maintenance,
                   @scheduler : Scheduler,
                   @broker : Broker,
                   @scheduler_on : Bool = true)
    end

    # False when `--no-scheduler` left `every` schedules to other processes.
    getter? scheduler_on : Bool

    # Fetches no new jobs, lets in-flight jobs and schedule blocks finish,
    # then closes the LISTEN connection and the pool.
    def stop : Nil
      WaitGroup.wait do |group|
        @workers.each { |worker| group.spawn { worker.stop } }
        group.spawn { @maintenance.stop }
        group.spawn { @scheduler.stop }
      end
      @broker.close
      ColdBrew.broker = nil if ColdBrew.broker?.same?(@broker)
      @db.close
    end
  end

  # Starts a worker per queue in CARAMEL_WORKER_QUEUES (comma-separated,
  # default `default`) with CARAMEL_WORKER_CONCURRENCY fibers each
  # (default 4), the maintenance fiber, the scheduler for every `every`
  # declaration unless `scheduler` is false, and the PubSub broker. Invalid
  # settings raise ConfigurationError before anything connects.
  def self.start(database_url : String, env = ENV, *, scheduler : Bool = true) : Service
    queues = worker_queues(env)
    concurrency = worker_concurrency(env, queues.size)
    pool_size = queues.size * concurrency + 1
    db = Caramel::Database.open(database_url, pool_size, "caramel-cold-brew")
    broker = Broker.new(database_url)
    self.broker = broker
    workers = queues.map { |queue| Worker.new(queue, concurrency, db).start }
    maintenance = Maintenance.new(db).start
    ticks = Scheduler.new(scheduler ? schedules : [] of Schedule, db).start
    Service.new(db, workers, maintenance, ticks, broker, scheduler)
  end

  # The distinct queue names CARAMEL_WORKER_QUEUES lists, default `default`.
  private def self.worker_queues(env) : Array(String)
    queues = (env["CARAMEL_WORKER_QUEUES"]? || "default").split(',').map(&.strip)
    queues.each do |queue|
      unless queue.matches?(QUEUE_NAME)
        message = "CARAMEL_WORKER_QUEUES names queues of 1-63 characters from " \
                  "[a-z0-9_.:-], separated by commas; got #{queue.inspect}"
        raise ConfigurationError.new(message)
      end
    end
    unless queues.uniq.size == queues.size
      raise ConfigurationError.new("CARAMEL_WORKER_QUEUES names a queue twice")
    end
    queues
  end

  # CARAMEL_WORKER_CONCURRENCY, default 4, within what the pool allows for
  # *queue_count* queues.
  private def self.worker_concurrency(env, queue_count : Int32) : Int32
    limit = (Caramel::Database::Config::MAX_POOL_SIZE - 1) // queue_count
    concurrency = (env["CARAMEL_WORKER_CONCURRENCY"]? || "4").to_i?
    unless concurrency && (1..limit).includes?(concurrency)
      message = "CARAMEL_WORKER_CONCURRENCY must be a whole number from 1 to #{limit} " \
                "for #{queue_count} queue(s)"
      raise ConfigurationError.new(message)
    end
    concurrency
  end
end
