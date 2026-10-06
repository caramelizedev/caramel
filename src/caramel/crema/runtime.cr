require "db"
require "../application"
require "../cold_brew"
require "../crema"

module Caramel::Crema
  alias Stopper = Proc(Nil)

  # One database pool's connections, as `/v1/status` and Prometheus report them.
  record PoolStats, name : String, open : Int32, idle : Int32, in_flight : Int32, max : Int32

  # The running process as the opt-in parts of Crema see it: the role it
  # plays, its database pools and its Cold Brew service. `CommandLine.serve`
  # and `CommandLine.work` start one and stop it on the way out.
  class Runtime
    getter role : String
    getter app : String
    getter started_at : Time = Time.utc
    getter database : DB::Database?
    getter cold_brew : ColdBrew::Service?
    getter application : Application?

    def initialize(@role : String,
                   @app : String,
                   @database : DB::Database? = nil,
                   @cold_brew : ColdBrew::Service? = nil,
                   @application : Application? = nil)
      @stoppers = [] of Stopper
    end

    def add_stopper(stopper : Stopper) : Nil
      @stoppers << stopper
    end

    # The web pool, and Cold Brew's pool when it runs in this process.
    def pools : Array(PoolStats)
      found = [] of PoolStats
      database.try { |db| found << stats(role == "serve" ? "web" : "cold_brew", db) }
      cold_brew.try { |service| found << stats("cold_brew", service.database) } if role == "serve"
      found
    end

    private def stats(name : String, db : DB::Database) : PoolStats
      pool = db.pool.stats
      PoolStats.new(name, pool.open_connections, pool.idle_connections,
        pool.in_flight_connections, pool.max_connections)
    end

    # Calls every stopper, newest first. One that raises is logged and the
    # rest still run.
    def stop : Nil
      @stoppers.reverse_each do |stopper|
        stopper.call
      rescue error
        LOG.warn { "stop failed error_type=#{error.class}" }
      end
      @stoppers.clear
      Crema.runtime = nil
    end
  end

  # True when *path* is a directory its owner alone can reach.
  def self.private_directory?(path : String) : Bool
    info = File.info?(path, follow_symlinks: false)
    return false if info.nil? || !info.directory?

    info.owner_id == LibC.getuid.to_s && (info.permissions.value & 0o077) == 0
  end

  def self.fiber_count : Int32
    count = 0
    Fiber.each { |_| count += 1 }
    count
  end

  # Fibers by name, a trailing `:<digits>` removed so one queue's workers count together.
  def self.fiber_groups : Hash(String, Int32)
    groups = Hash(String, Int32).new(0)
    Fiber.each { |fiber| groups[fiber.name.try(&.sub(/:\d+\z/, "")) || "(unnamed)"] += 1 }
    groups
  end

  @@runtime : Runtime?
  @@starters = [] of Proc(Runtime, Stopper?)

  def self.runtime? : Runtime?
    @@runtime
  end

  # :nodoc:
  def self.runtime=(runtime : Runtime?) : Runtime?
    @@runtime = runtime
  end

  # Registers *block* to run in `Crema.start`, in registration order. It
  # returns a proc that undoes what it started, or nil.
  def self.on_start(&block : Runtime -> Stopper?) : Nil
    @@starters << block
  end

  def self.start(role : String,
                 app : String,
                 *,
                 database : DB::Database? = nil,
                 cold_brew : ColdBrew::Service? = nil,
                 application : Application? = nil) : Runtime
    runtime = Runtime.new(role, app, database, cold_brew, application)
    @@runtime = runtime
    application.try { |found| Crema.debug_key = found.csrf.derive_key("crema-debug") }
    @@starters.each do |starter|
      starter.call(runtime).try { |stopper| runtime.add_stopper(stopper) }
    rescue error
      LOG.warn { "start failed error_type=#{error.class}" }
    end
    runtime
  end
end

require "./ops"

module Caramel::Crema
  on_start { |runtime| Ops.start(runtime) }
end

{% if flag?(:caramel_development) %}
  require "./dev_sink"
{% end %}
