require "json"
require "log"
require "../../sugar_orm"

module Caramel::ColdBrew
  HookLog = ::Log.for("cold_brew.hooks")

  # A failed run that Cold Brew rescheduled: the job's row holds the new
  # `run_at` and the run's error. `error_class` names the exception; its
  # message stays in the database.
  record RetryScheduled, id : Int64, queue : String, class_name : String, attempts : Int32, run_at : Time, error_class : String do
    include JSON::Serializable
  end

  # A job that will not run again: its row holds `failed_at` and the error.
  record JobFailed, id : Int64, queue : String, class_name : String, attempts : Int32, failed_at : Time, error_class : String do
    include JSON::Serializable
  end

  @@retry_hooks = [] of RetryScheduled ->
  @@failure_hooks = [] of JobFailed ->

  # Calls the block each time a failed run is rescheduled, after the
  # transition is written. Register hooks at boot, before `start`:
  #
  #     Caramel::ColdBrew.on_retry_scheduled do |event|
  #       Caramel::ColdBrew.publish("deliveries", event.to_json)
  #     end
  #
  # Under a worker the transition has committed when the hook runs, and the
  # hook runs in a transaction of its own: its `publish` is delivered and its
  # `enqueue` committed when it returns, and an exception rolls back only the
  # hook's writes and is logged by class. Hooks run on the worker's fiber, so
  # keep them short. Under `drain_queue!` on a spec's connection, hooks run
  # inside the example's transaction. A job released after its process died
  # was never recorded as failed, so it fires no hook.
  def self.on_retry_scheduled(&hook : RetryScheduled ->) : Nil
    @@retry_hooks << hook
  end

  # Calls the block each time a job fails for good, after the transition is
  # written; see `on_retry_scheduled` for when hooks run.
  def self.on_failed(&hook : JobFailed ->) : Nil
    @@failure_hooks << hook
  end

  # :nodoc:
  def self.notify(event : RetryScheduled) : Nil
    @@retry_hooks.each { |hook| call_hook(hook, event, "on_retry_scheduled") }
  end

  # :nodoc:
  def self.notify(event : JobFailed) : Nil
    @@failure_hooks.each { |hook| call_hook(hook, event, "on_failed") }
  end

  private def self.call_hook(hook : T ->, event : T, name : String) : Nil forall T
    SugarORM::Repo.transaction { hook.call(event) }
  rescue error
    # The message may carry connection details; the class is enough to act on.
    HookLog.error { "hook=#{name} job=#{event.id} class=#{event.class_name} error_type=#{error.class}" }
  end
end
