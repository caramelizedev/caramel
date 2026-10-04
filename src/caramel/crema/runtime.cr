require "db"
require "../application"
require "../cold_brew"
require "../crema"

module Caramel::Crema
  alias Stopper = Proc(Nil)

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
    @@starters.each do |starter|
      starter.call(runtime).try { |stopper| runtime.add_stopper(stopper) }
    rescue error
      LOG.warn { "start failed error_type=#{error.class}" }
    end
    runtime
  end
end

{% if flag?(:caramel_development) %}
  require "./dev_sink"
{% end %}
