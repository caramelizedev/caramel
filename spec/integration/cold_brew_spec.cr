require "spec"
require "log/spec"
require "random/secure"
require "../../src/caramel"

# Only scripts/check integration supplies these URLs for its newly owned cluster.
private COLD_BREW_ADMIN_URL   = ENV["CARAMEL_OWNED_ADMIN_URL"]? || raise "Run scripts/check integration; no owned admin connection provided"
private COLD_BREW_OWNER_URL   = ENV["CARAMEL_OWNED_SPEC_URL"]? || raise "Run scripts/check integration; no owned test database provided"
private COLD_BREW_RUNTIME_URL = ENV["CARAMEL_OWNED_MODEL_RUNTIME_URL"]? || raise "Run scripts/check integration; no runtime role URL provided"

module ColdBrewSpec
  class Flaky < Exception
  end

  class Throttled < Exception
  end

  Caramel::ColdBrew::Job.retry_on ColdBrewSpec::Throttled, attempts: 4, backoff: :linear, base: 5.seconds
  Caramel::ColdBrew::Job.retry_on ColdBrewSpec::Flaky, attempts: 9, backoff: :linear, base: 1.second

  # Jobs record their runs in cold_brew_runs from inside perform's transaction.
  struct Record < Caramel::ColdBrew::Job
    param label : String

    def perform
      SugarORM.sql_exec("INSERT INTO cold_brew_runs (label, backend) VALUES ($1, pg_backend_pid())", label)
    end
  end

  struct Busy < Caramel::ColdBrew::Job
    queue "busy"
    param label : String

    def perform
      SugarORM.sql_exec("INSERT INTO cold_brew_runs (label, backend) SELECT $1, pg_backend_pid() FROM pg_sleep(0.005)", label)
    end
  end

  # Its own rule wins over the global Flaky rule.
  struct Fragile < Caramel::ColdBrew::Job
    queue "fragile"
    retry_on ColdBrewSpec::Flaky, attempts: 2, backoff: :linear, base: 30.seconds
    param label : String

    def perform
      SugarORM.sql_exec("INSERT INTO cold_brew_runs (label) VALUES ($1)", label)
      raise Flaky.new("boom #{label}")
    end
  end

  struct Throttle < Caramel::ColdBrew::Job
    queue "fragile"

    def perform
      raise Throttled.new("slow down")
    end
  end

  struct Crash < Caramel::ColdBrew::Job
    queue "fragile"

    def perform
      raise "unexpected"
    end
  end

  struct Chain < Caramel::ColdBrew::Job
    param depth : Int32

    def perform
      SugarORM.sql_exec("INSERT INTO cold_brew_runs (label) VALUES ($1)", "chain #{depth}")
      Chain.enqueue(depth: depth - 1) if depth > 1
    end
  end

  struct Forever < Caramel::ColdBrew::Job
    queue "forever"

    def perform
      Forever.enqueue
    end
  end

  struct Gated < Caramel::ColdBrew::Job
    queue "gated"
    param label : String

    def perform
      ColdBrewSpec.gate.receive
      SugarORM.sql_exec("INSERT INTO cold_brew_runs (label) VALUES ($1)", label)
    end
  end

  struct Announce < Caramel::ColdBrew::Job
    param board : Int64

    def perform
      SugarORM.sql_exec("INSERT INTO cold_brew_runs (label) VALUES ($1)", "announced #{board}")
      Caramel::ColdBrew.publish("board_#{board}", "job finished")
    end
  end

  module Boards
    abstract struct Page < Caramel::Action
      def layout(page : Caramel::Page) : String
        page.body
      end
    end

    # RFC-0003 §2.3, verbatim apart from the base struct.
    struct Live < Page
      contract do
        field board_id : Int64
      end

      def handle(contract : Contract)
        channel = Channel(String).new
        Caramel::ColdBrew.subscribe("board_#{contract.board_id}", channel)

        stream "text/event-stream" do |io|
          loop do
            io << "event: BoardUpdated\ndata: " << channel.receive << "\n\n"
            io.flush
          end
        end
      end
    end
  end

  Caramel::Router.draw do
    get "/boards/:board_id/live", ColdBrewSpec::Boards::Live
  end

  # Ticks in every process whose scheduler is on.
  Caramel::ColdBrew.every(1.hour, "cold-brew-spec-tick") { }

  # A lifecycle event, and whether another connection already saw the
  # transition when the hook ran.
  record Seen,
    kind : String,
    id : Int64,
    queue : String,
    attempts : Int32,
    at : Time,
    error_class : String,
    committed : Bool

  @@seen = [] of Seen
  # "publish", "raise" or "sql" changes what the hooks do after recording.
  @@hook_mode : String? = nil

  def self.seen : Array(Seen)
    @@seen
  end

  def self.seen(kind : String) : Seen
    @@seen.find! { |seen| seen.kind == kind }
  end

  def self.hook_mode=(@@hook_mode : String?)
  end

  Caramel::ColdBrew.on_retry_scheduled do |event|
    ColdBrewSpec.observe("retry", event, at: event.run_at)
  end

  Caramel::ColdBrew.on_failed do |event|
    ColdBrewSpec.observe("failed", event, at: event.failed_at)
  end

  def self.observe(kind : String, event, *, at : Time) : Nil
    @@seen << Seen.new(
      kind: kind,
      id: event.id,
      queue: event.queue,
      attempts: event.attempts,
      at: at,
      error_class: event.error_class,
      committed: committed?(kind, event.id),
    )
    case @@hook_mode
    when "publish" then Caramel::ColdBrew.publish("job_events", "#{kind} #{event.id}")
    when "raise"   then raise "hook broke"
    when "sql"     then SugarORM.sql_exec("SELECT 1 / 0")
    end
  end

  # Whether the owner's own connection already sees the transition.
  private def self.committed?(kind : String, id : Int64) : Bool
    column = kind == "retry" ? "last_error" : "failed_at"
    sql = "SELECT #{column} IS NOT NULL AND locked_at IS NULL AS value " \
          "FROM caramel_jobs WHERE id = $1"
    rows = SugarORM.sql(owner, sql, id, as: {value: Bool})
    rows.first?.try(&.[:value]) || false
  end

  NAME = "caramel_cold_brew_#{Random::Secure.hex(6)}"
  RUNS = SugarORM::Migration.new(20260927120000_i64, "create_cold_brew_runs", [<<-SQL])
    CREATE TABLE cold_brew_runs (
      id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      label text NOT NULL,
      backend integer,
      created_at timestamptz NOT NULL DEFAULT clock_timestamp()
    )
    SQL

  @@owner : DB::Database? = nil
  @@runtime : DB::Database? = nil
  @@gate = Channel(Nil).new

  def self.gate : Channel(Nil)
    @@gate
  end

  def self.url(base : String) : String
    base.sub("/caramel_spec?", "/#{NAME}?")
  end

  # A scratch database owned by the spec role, which migrates it as a Latte
  # migration role would. The runtime role gets only CONNECT, schema USAGE
  # and DML, like a Latte runtime role.
  def self.owner : DB::Database
    @@owner ||= begin
      admin = Caramel::Database.open(COLD_BREW_ADMIN_URL, 1)
      begin
        admin.exec(%(CREATE DATABASE "#{NAME}" OWNER caramel_spec))
        admin.exec(%(REVOKE CONNECT, TEMPORARY ON DATABASE "#{NAME}" FROM PUBLIC))
        admin.exec(%(GRANT CONNECT ON DATABASE "#{NAME}" TO caramel_spec, caramel_model_spec))
      ensure
        admin.close
      end
      owner = Caramel::Database.open(url(COLD_BREW_OWNER_URL), 4)
      owner.exec("REVOKE ALL ON SCHEMA public FROM PUBLIC")
      owner.exec("GRANT USAGE ON SCHEMA public TO caramel_model_spec")
      owner.exec("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO caramel_model_spec")
      owner.exec("ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO caramel_model_spec")
      SugarORM::Migrator.new(owner, Caramel::ColdBrew::MIGRATIONS + [RUNS]).migrate
      owner
    end
  end

  def self.runtime : DB::Database
    @@runtime ||= Caramel::Database.open(url(COLD_BREW_RUNTIME_URL), 16)
  end

  def self.runtime_url : String
    url(COLD_BREW_RUNTIME_URL)
  end

  def self.reset : DB::Database
    @@seen.clear
    @@hook_mode = nil
    owner.exec("TRUNCATE caramel_jobs, caramel_cache, caramel_schedules, cold_brew_runs")
    SugarORM::Repo.database = runtime
  end

  def self.drop : Nil
    return unless @@owner
    @@runtime.try(&.close)
    @@owner.try(&.close)
    admin = Caramel::Database.open(COLD_BREW_ADMIN_URL, 1)
    admin.exec(%(DROP DATABASE IF EXISTS "#{NAME}" WITH (FORCE)))
    admin.close
  end

  def self.labels(db : SugarORM::Handle = owner) : Array(String)
    SugarORM.sql(db, "SELECT label FROM cold_brew_runs ORDER BY id", as: {label: String}).map(&.[:label])
  end

  def self.scalar(sql : String, *args, as type : T.class) : T forall T
    SugarORM.sql(owner, sql, *args, as: {value: T}).first[:value]
  end

  def self.job(id : Int64)
    SugarORM.sql(owner, <<-SQL, id, as: {attempts: Int32, locked_at: Time?, locked_by: String?, failed_at: Time?, finished_at: Time?, last_error: String?, delay: Float64}).first
      SELECT attempts, locked_at, locked_by, failed_at, finished_at, last_error, EXTRACT(EPOCH FROM run_at - now())::float8 AS delay
      FROM caramel_jobs WHERE id = $1
      SQL
  end

  # A job whose class this process does not define.
  def self.vanished(queue : String = "default") : Int64
    scalar(<<-SQL, queue, as: Int64)
      INSERT INTO caramel_jobs (queue, class_name, payload)
      VALUES ($1, 'Vanished::Job', '{}') RETURNING id AS value
      SQL
  end

  def self.schedule_count : Int64
    scalar("SELECT count(*) AS value FROM caramel_schedules", as: Int64)
  end

  # Runs one worker fiber on `queue` for the block.
  def self.working(queue : String, &) : Nil
    worker = Caramel::ColdBrew::Worker.new(queue, 1, runtime).start
    begin
      yield
    ensure
      worker.stop
    end
  end

  def self.partitions : Array(String)
    SugarORM.sql(owner, <<-SQL, as: {name: String}).map(&.[:name])
      SELECT c.relname::text AS name FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
      WHERE i.inhparent = 'caramel_jobs'::regclass ORDER BY 1
      SQL
  end

  def self.day(offset : Int32) : String
    "caramel_jobs_p#{(Time.utc.at_beginning_of_day + offset.days).to_s("%Y_%m_%d")}"
  end

  def self.eventually(timeout : Time::Span = 10.seconds, &) : Nil
    deadline = Time.instant + timeout
    until yield
      raise "Condition not met within #{timeout.total_seconds} s" if Time.instant > deadline
      sleep 20.milliseconds
    end
  end

  def self.receive?(channel : Channel(String), timeout : Time::Span) : String?
    select
    when payload = channel.receive
      payload
    when timeout(timeout)
      nil
    end
  end

  def self.with_broker(&) : Nil
    broker = Caramel::ColdBrew::Broker.new(runtime_url)
    Caramel::ColdBrew.broker = broker
    begin
      yield broker
    ensure
      broker.close
      Caramel::ColdBrew.broker = nil
    end
  end
end

Spec.after_suite { ColdBrewSpec.drop }

private alias Brew = Caramel::ColdBrew

describe "Caramel::ColdBrew system tables" do
  it "migrate under the zero-lock linter with this week's partitions, and the SugarORM differ ignores them" do
    ColdBrewSpec.reset
    SugarORM::Linter.lint(Brew::MIGRATIONS).should be_empty
    ColdBrewSpec.partitions.should eq(["caramel_jobs_default"] + (0..7).map { |offset| ColdBrewSpec.day(offset) })
    ColdBrewSpec.scalar("SELECT relpersistence::text AS value FROM pg_class WHERE oid = 'caramel_cache'::regclass", as: String).should eq("u")
    ColdBrewSpec.scalar("SELECT pg_get_indexdef('caramel_jobs_fetch'::regclass) AS value", as: String)
      .should end_with("(queue, run_at, priority DESC) WHERE ((locked_at IS NULL) AND (failed_at IS NULL) AND (finished_at IS NULL))")
    plan = SugarORM::Differ.diff([] of SugarORM::Catalog::Table, SugarORM::Introspection.read(ColdBrewSpec.owner))
    plan.clean?.should be_true
    %w[caramel_jobs caramel_jobs_default caramel_cache caramel_schedules].each do |table|
      plan.notes.should contain("ignored table #{table} (owned by Caramel)")
    end
    plan.notes.should contain("ignored table #{ColdBrewSpec.day(7)} (owned by Caramel)")
    plan.notes.select(&.includes?(" on caramel_")).should be_empty
  end
end

describe "Caramel::ColdBrew::Job.enqueue" do
  it "commits and rolls back with the business write in Repo.transaction" do
    ColdBrewSpec.reset
    committed = 0_i64
    SugarORM::Repo.transaction do
      SugarORM.sql_exec("INSERT INTO cold_brew_runs (label) VALUES ('order 1')")
      committed = ColdBrewSpec::Record.enqueue(label: "receipt 1", priority: 5)
    end
    SugarORM::Repo.transaction do
      SugarORM.sql_exec("INSERT INTO cold_brew_runs (label) VALUES ('order 2')")
      ColdBrewSpec::Record.enqueue(label: "receipt 2")
      SugarORM::Repo.rollback
    end
    expect_raises(Exception, "payment declined") do
      SugarORM::Repo.transaction do
        SugarORM.sql_exec("INSERT INTO cold_brew_runs (label) VALUES ('order 3')")
        ColdBrewSpec::Record.enqueue(label: "receipt 3")
        raise "payment declined"
      end
    end
    ColdBrewSpec.labels.should eq(["order 1"])
    SugarORM.sql(ColdBrewSpec.owner, "SELECT id, queue, class_name, payload::text AS payload, priority, attempts FROM caramel_jobs",
      as: {id: Int64, queue: String, class_name: String, payload: String, priority: Int32, attempts: Int32})
      .should eq([{id: committed, queue: "default", class_name: "ColdBrewSpec::Record", payload: %({"label": "receipt 1"}), priority: 5, attempts: 0}])
  end

  it "writes through an explicit handle into the job's queue at run_at" do
    ColdBrewSpec.reset
    at = 10.minutes.from_now
    id = ColdBrewSpec::Busy.enqueue(ColdBrewSpec.runtime, label: "later", run_at: at)
    row = SugarORM.sql(ColdBrewSpec.owner, "SELECT queue, run_at FROM caramel_jobs WHERE id = $1", id, as: {queue: String, run_at: Time}).first
    row[:queue].should eq("busy")
    (row[:run_at] - at).abs.should be < 1.millisecond
  end
end

describe Caramel::ColdBrew::Worker do
  it "never runs a job twice across two concurrent workers (SKIP LOCKED), each on the connection that claimed it" do
    ColdBrewSpec.reset
    60.times { |index| ColdBrewSpec::Busy.enqueue(label: "job #{index}") }
    other = Caramel::Database.open(ColdBrewSpec.runtime_url, 4)
    first = Brew::Worker.new("busy", 4, ColdBrewSpec.runtime).start
    second = Brew::Worker.new("busy", 4, other).start
    begin
      ColdBrewSpec.eventually(20.seconds) { ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_jobs WHERE finished_at IS NOT NULL", as: Int64) == 60 }
    ensure
      first.stop
      second.stop
      other.close
    end
    runs = SugarORM.sql(ColdBrewSpec.owner, "SELECT label, count(*) AS runs FROM cold_brew_runs GROUP BY label", as: {label: String, runs: Int64})
    runs.size.should eq(60)
    runs.map(&.[:runs]).uniq!.should eq([1])
    ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_jobs WHERE attempts <> 1", as: Int64).should eq(0)
    ColdBrewSpec.scalar(<<-SQL, as: Int64).should eq(60)
      SELECT count(*) AS value FROM caramel_jobs j JOIN cold_brew_runs r ON r.label = j.payload->>'label' AND r.backend::text = j.locked_by
      SQL
    ColdBrewSpec.scalar("SELECT count(DISTINCT backend) AS value FROM cold_brew_runs", as: Int64).should be >= 2
  end

  it "runs no job before its run_at, the highest priority first" do
    ColdBrewSpec.reset
    later = ColdBrewSpec::Record.enqueue(label: "later", run_at: 1500.milliseconds.from_now)
    ColdBrewSpec::Record.enqueue(label: "low")
    ColdBrewSpec::Record.enqueue(label: "high", priority: 10)
    worker = Brew::Worker.new("default", 1, ColdBrewSpec.runtime).start
    begin
      ColdBrewSpec.eventually { ColdBrewSpec.labels.size == 2 }
      ColdBrewSpec.labels.should eq(["high", "low"])
      ColdBrewSpec.job(later)[:finished_at].should be_nil
      ColdBrewSpec.eventually(5.seconds) { ColdBrewSpec.labels.size == 3 }
    ensure
      worker.stop
    end
    ColdBrewSpec.scalar("SELECT finished_at >= run_at AS value FROM caramel_jobs WHERE id = $1", later, as: Bool).should be_true
  end

  it "stops gracefully: the in-flight job finishes and no new job starts" do
    ColdBrewSpec.reset
    running = ColdBrewSpec::Gated.enqueue(label: "in flight")
    waiting = ColdBrewSpec::Gated.enqueue(label: "never started")
    worker = Brew::Worker.new("gated", 1, ColdBrewSpec.runtime).start
    ColdBrewSpec.eventually { !ColdBrewSpec.job(running)[:locked_at].nil? }
    stopped = Channel(Nil).new(1)
    spawn do
      worker.stop
      stopped.send(nil)
    end
    select
    when stopped.receive
      fail "stop returned while a job was still running"
    when timeout(200.milliseconds)
    end
    ColdBrewSpec.gate.send(nil)
    select
    when stopped.receive
    when timeout(5.seconds)
      fail "stop did not return after the in-flight job finished"
    end
    ColdBrewSpec.job(running)[:finished_at].should_not be_nil
    ColdBrewSpec.labels.should eq(["in flight"])
    ColdBrewSpec.job(waiting)[:attempts].should eq(0)
  end
end

describe "Caramel::ColdBrew retries" do
  it "reschedules with the job's own backoff, rolls back its writes, then fails it" do
    ColdBrewSpec.reset
    id = ColdBrewSpec::Fragile.enqueue(label: "first")
    Brew.drain_queue(ColdBrewSpec.runtime, "fragile").should eq(1)
    row = ColdBrewSpec.job(id)
    row[:attempts].should eq(1)
    row[:failed_at].should be_nil
    row[:locked_at].should be_nil
    row[:locked_by].should be_nil
    row[:last_error].not_nil!.should start_with("ColdBrewSpec::Flaky: boom first")
    row[:delay].should be_close(30.0, 1.0)
    ColdBrewSpec.labels.should be_empty

    Brew.drain_queue(ColdBrewSpec.runtime, "fragile").should eq(0)
    error = expect_raises(Brew::DrainFailure) { Brew.drain_queue!(ColdBrewSpec.runtime, "fragile", include_scheduled: true) }
    error.failures.map(&.id).should eq([id])
    error.message.not_nil!.should contain("ColdBrewSpec::Fragile ##{id} (attempt 2): ColdBrewSpec::Flaky: boom first")
    row = ColdBrewSpec.job(id)
    row[:attempts].should eq(2)
    row[:failed_at].should_not be_nil
    row[:last_error].not_nil!.should start_with("ColdBrewSpec::Flaky: boom first")
    Brew.drain_queue(ColdBrewSpec.runtime, "fragile", include_scheduled: true).should eq(0)
  end

  it "falls back to the global retry_on, then to 3 exponential attempts from 1 second" do
    ColdBrewSpec.reset
    throttle = ColdBrewSpec::Throttle.enqueue
    crash = ColdBrewSpec::Crash.enqueue
    delays = [] of {Float64, Float64}
    4.times do
      Brew.drain_queue(ColdBrewSpec.runtime, "fragile", include_scheduled: true)
      delays << {ColdBrewSpec.job(throttle)[:delay], ColdBrewSpec.job(crash)[:delay]}
    end
    delays.map(&.[0].round).first(3).should eq([5.0, 10.0, 15.0])
    delays.map(&.[1].round).first(2).should eq([1.0, 2.0])
    ColdBrewSpec.job(crash)[:attempts].should eq(3)
    ColdBrewSpec.job(crash)[:failed_at].should_not be_nil
    ColdBrewSpec.job(crash)[:last_error].not_nil!.should start_with("Exception: unexpected")
    ColdBrewSpec.job(throttle)[:attempts].should eq(4)
    ColdBrewSpec.job(throttle)[:failed_at].should_not be_nil
  end

  it "fails a row whose job class is not compiled into the application" do
    ColdBrewSpec.reset
    id = ColdBrewSpec.scalar("INSERT INTO caramel_jobs (class_name, payload) VALUES ('Vanished::Job', '{}') RETURNING id AS value", as: Int64)
    Brew.drain_queue(ColdBrewSpec.runtime).should eq(1)
    row = ColdBrewSpec.job(id)
    row[:attempts].should eq(1)
    row[:failed_at].should_not be_nil
    row[:last_error].not_nil!.should start_with("Caramel::ColdBrew::UnknownJob: No Caramel::ColdBrew::Job named Vanished::Job")
  end
end

describe "Caramel::ColdBrew.status" do
  it "reports each job's state from its row, naming only its last error's class" do
    ColdBrewSpec.reset
    scheduled = ColdBrewSpec::Record.enqueue(label: "later", run_at: 1.hour.from_now)
    queued = ColdBrewSpec::Record.enqueue(label: "now")
    retrying = ColdBrewSpec::Fragile.enqueue(label: "once")
    Brew.drain_queue(ColdBrewSpec.runtime, "fragile").should eq(1)

    statuses = Brew.statuses([scheduled, queued, retrying, 999_999_i64])
    statuses.keys.sort!.should eq([scheduled, queued, retrying].sort)
    statuses[scheduled].state.should eq(Brew::JobState::Scheduled)
    statuses[queued].state.should eq(Brew::JobState::Queued)
    statuses[queued].attempts.should eq(0)
    statuses[queued].error_class.should be_nil

    retried = statuses[retrying]
    retried.state.should eq(Brew::JobState::Retrying)
    retried.queue.should eq("fragile")
    retried.class_name.should eq("ColdBrewSpec::Fragile")
    retried.attempts.should eq(1)
    retried.error_class.should eq("ColdBrewSpec::Flaky")
    (retried.run_at - Time.utc).should be_close(30.seconds, 2.seconds)
    retried.to_json.should_not contain("boom")
    JSON.parse(retried.to_json)["state"].should eq("retrying")
    Brew.status(999_999_i64).should be_nil
    Brew.statuses([] of Int64).should be_empty

    vanished = ColdBrewSpec.vanished
    Brew.drain_queue(ColdBrewSpec.runtime).should eq(2)
    finished = Brew.status(ColdBrewSpec.owner, queued).not_nil!
    finished.state.should eq(Brew::JobState::Finished)
    finished.attempts.should eq(1)
    finished.finished_at.should_not be_nil
    failed = Brew.status(vanished).not_nil!
    failed.state.should eq(Brew::JobState::Failed)
    failed.error_class.should eq("Caramel::ColdBrew::UnknownJob")
    failed.failed_at.should_not be_nil

    running = ColdBrewSpec::Gated.enqueue(label: "held")
    worker = Brew::Worker.new("gated", 1, ColdBrewSpec.runtime).start
    begin
      ColdBrewSpec.eventually { Brew.status(running).try(&.state.running?) || false }
      Brew.status(running).not_nil!.attempts.should eq(1)
    ensure
      ColdBrewSpec.gate.send(nil)
      worker.stop
    end
    Brew.status(running).not_nil!.state.should eq(Brew::JobState::Finished)
  end
end

describe "Caramel::ColdBrew lifecycle hooks" do
  it "run after a worker commits a retry or a failure" do
    ColdBrewSpec.reset
    retried = ColdBrewSpec::Fragile.enqueue(label: "hooked")
    vanished = ColdBrewSpec.vanished("fragile")
    ColdBrewSpec.working("fragile") do
      ColdBrewSpec.eventually { ColdBrewSpec.seen.size == 2 }
    end

    retry = ColdBrewSpec.seen("retry")
    {retry.id, retry.queue, retry.attempts}.should eq({retried, "fragile", 1})
    retry.error_class.should eq("ColdBrewSpec::Flaky")
    retry.committed.should be_true
    (retry.at - Time.utc).should be_close(30.seconds, 2.seconds)

    failure = ColdBrewSpec.seen("failed")
    {failure.id, failure.queue, failure.attempts}.should eq({vanished, "fragile", 1})
    failure.error_class.should eq("Caramel::ColdBrew::UnknownJob")
    failure.committed.should be_true
  end

  it "can publish what a dashboard needs to hear" do
    ColdBrewSpec.reset
    ColdBrewSpec.hook_mode = "publish"
    ColdBrewSpec.with_broker do
      Brew.subscribe("job_events") do |updates|
        id = ColdBrewSpec::Crash.enqueue
        ColdBrewSpec.working("fragile") do
          ColdBrewSpec.receive?(updates, 5.seconds).should eq("retry #{id}")
        end
      end
    end
  end

  it "keep a failing hook from stopping a worker or aborting a drain's transaction" do
    ColdBrewSpec.reset
    ColdBrewSpec.hook_mode = "raise"
    vanished = ColdBrewSpec.vanished
    ColdBrewSpec::Record.enqueue(label: "after")
    Log.capture("cold_brew.hooks") do |logs|
      ColdBrewSpec.working("default") do
        ColdBrewSpec.eventually { ColdBrewSpec.labels == ["after"] }
      end
      entry = /\Ahook=on_failed job=#{vanished} class=Vanished::Job error_type=Exception\z/
      logs.check(:error, entry)
    end
    Brew.status(vanished).not_nil!.state.should eq(Brew::JobState::Failed)

    ColdBrewSpec.hook_mode = "sql"
    ColdBrewSpec.runtime.using_connection do |connection|
      connection.transaction do |transaction|
        SugarORM::Repo.bind(transaction) do
          crashed = ColdBrewSpec::Crash.enqueue
          Brew.drain_queue(connection, "fragile").should eq(1)
          # The hook's error rolled back only its own savepoint.
          ColdBrewSpec.labels(connection).should eq(["after"])
          status = Brew.status(connection, crashed).not_nil!
          status.state.should eq(Brew::JobState::Retrying)
        end
        transaction.rollback
      end
    end
  end
end

describe "Caramel::ColdBrew.drain_queue!" do
  it "runs due jobs synchronously on the caller's transaction, including jobs enqueued by jobs" do
    ColdBrewSpec.reset
    ColdBrewSpec.runtime.using_connection do |connection|
      connection.transaction do |transaction|
        SugarORM::Repo.bind(transaction) do
          ColdBrewSpec::Chain.enqueue(depth: 3)
          ColdBrewSpec::Record.enqueue(label: "tomorrow", run_at: 1.day.from_now)
          Brew.drain_queue!(connection, "default").should eq(3)
          ColdBrewSpec.labels(connection).should eq(["chain 3", "chain 2", "chain 1"])
          Brew.drain_queue!(connection, "default", include_scheduled: true).should eq(1)
          ColdBrewSpec.labels(connection).last.should eq("tomorrow")

          ColdBrewSpec::Fragile.enqueue(label: "doomed")
          expect_raises(Brew::DrainFailure, "boom doomed") { Brew.drain_queue!(connection, "fragile") }
          ColdBrewSpec.labels(connection).should_not contain("doomed")
          ColdBrewSpec.labels(connection).size.should eq(4)
        end
        transaction.rollback
      end
    end
    ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_jobs", as: Int64).should eq(0)
    ColdBrewSpec.labels.should be_empty
  end

  it "gives up after #{Caramel::ColdBrew::DRAIN_LIMIT} runs when a job keeps enqueuing itself" do
    ColdBrewSpec.reset
    ColdBrewSpec::Forever.enqueue
    expect_raises(Brew::DrainLimitExceeded, "ran #{Brew::DRAIN_LIMIT} jobs") { Brew.drain_queue(ColdBrewSpec.runtime, "forever") }
    ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_jobs WHERE finished_at IS NOT NULL", as: Int64).should eq(Brew::DRAIN_LIMIT)
  end
end

describe Caramel::ColdBrew::Maintenance do
  it "creates this week's partitions and drops old ones holding only finished or failed jobs, as the runtime role" do
    ColdBrewSpec.reset
    runtime = ColdBrewSpec.runtime
    expect_raises(PQ::PQError, "permission denied") { runtime.exec("CREATE TABLE intruder (id int)") }
    ColdBrewSpec.owner.exec(%(DROP TABLE "#{ColdBrewSpec.day(7)}"))
    [-10, -9, -3].each { |offset| runtime.exec("SELECT caramel_jobs_create_partitions((now() AT TIME ZONE 'UTC')::date + $1::int, 0)", offset) }
    insert = "INSERT INTO caramel_jobs (class_name, payload, enqueued_at, finished_at, failed_at) VALUES ('Old', '{}', now() - make_interval(days => $1), $2, $3)"
    now = Time.utc
    # {age in days, finished_at, failed_at}: nothing pending 10 days ago, one
    # pending job 9 days ago, and 30 days ago (no partition, so the default one).
    rows = [{10, now, nil}, {10, nil, now}, {9, now, nil}, {9, nil, nil}, {3, now, nil}, {30, now, nil}, {30, nil, nil}] of {Int32, Time?, Time?}
    rows.each do |age, finished, failed|
      runtime.exec(insert, age, finished, failed)
    end

    report = Brew::Maintenance.new(runtime).run_once
    report.created.should eq(1)
    report.dropped.should eq(1)
    partitions = ColdBrewSpec.partitions
    partitions.should_not contain(ColdBrewSpec.day(-10))
    partitions.should contain(ColdBrewSpec.day(-9))
    partitions.should contain(ColdBrewSpec.day(-3))
    partitions.should contain(ColdBrewSpec.day(7))
    ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_jobs_default", as: Int64).should eq(1)
    ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_jobs WHERE finished_at IS NULL AND failed_at IS NULL", as: Int64).should eq(2)
    # A day whose rows already sit in the default partition is skipped, not an error.
    ColdBrewSpec.scalar("SELECT caramel_jobs_create_partitions((now() AT TIME ZONE 'UTC')::date - 30, 0) AS value", as: Int32).should eq(0)
  end

  it "refuses out-of-range partition requests from the runtime role" do
    ColdBrewSpec.reset
    runtime = ColdBrewSpec.runtime
    expect_raises(PQ::PQError, /days must be between 0 and 366/) { runtime.exec("SELECT caramel_jobs_create_partitions(current_date, 367)") }
    expect_raises(PQ::PQError, /days must be between 0 and 366/) { runtime.exec("SELECT caramel_jobs_create_partitions(current_date, -1)") }
    expect_raises(PQ::PQError, /retention must be at least one day/) { runtime.exec("SELECT caramel_jobs_drop_partitions(interval '1 hour')") }
    ColdBrewSpec.partitions.should contain(ColdBrewSpec.day(0))
    expect_raises(ArgumentError, "retention must be at least one day") { Brew::Maintenance.new(runtime, retention: 1.hour) }
  end

  it "releases a stale lock only when its backend is gone" do
    ColdBrewSpec.reset
    ColdBrewSpec.owner.using_connection do |live|
      pid = live.scalar("SELECT pg_backend_pid()").as(Int32)
      insert = "INSERT INTO caramel_jobs (class_name, payload, attempts, locked_at, locked_by) VALUES ('ColdBrewSpec::Record', jsonb_build_object('label', $1::text), 1, now() - make_interval(mins => $2), $3) RETURNING id AS value"
      crashed = ColdBrewSpec.scalar(insert, "crashed", 20, "0", as: Int64)
      ColdBrewSpec.scalar(insert, "still running", 20, pid.to_s, as: Int64)
      ColdBrewSpec.scalar(insert, "recent", 1, "0", as: Int64)
      Brew::Maintenance.new(ColdBrewSpec.runtime).run_once.released.should eq(1)
      ColdBrewSpec.job(crashed)[:locked_at].should be_nil
      Brew.drain_queue(ColdBrewSpec.runtime).should eq(1)
      ColdBrewSpec.labels.should eq(["crashed"])
    end
  end

  it "runs its passes from a fiber until stopped" do
    ColdBrewSpec.reset
    ColdBrewSpec.owner.exec("INSERT INTO caramel_cache (key, value, expires_at) VALUES ('stale', 'x', now() - interval '1 second')")
    maintenance = Brew::Maintenance.new(ColdBrewSpec.runtime, interval: 50.milliseconds).start
    begin
      ColdBrewSpec.eventually { ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_cache", as: Int64) == 0 }
    ensure
      maintenance.stop
    end
  end
end

describe Caramel::Cache do
  it "reads entries until their TTL passes, and the vacuum removes them" do
    ColdBrewSpec.reset
    Caramel::Cache.write("forever", "a")
    Caramel::Cache.write("brief", "b", expires_in: 200.milliseconds)
    Caramel::Cache.read("brief").should eq("b")
    sleep 300.milliseconds
    Caramel::Cache.read("brief").should be_nil
    Caramel::Cache.read("forever").should eq("a")
    ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_cache", as: Int64).should eq(2)
    Brew::Maintenance.new(ColdBrewSpec.runtime).run_once.expired.should eq(1)
    ColdBrewSpec.scalar("SELECT string_agg(key, ',') AS value FROM caramel_cache", as: String).should eq("forever")
  end

  it "fetches once, replaces, deletes and clears" do
    ColdBrewSpec.reset
    calls = 0
    2.times { Caramel::Cache.fetch("report", expires_in: 1.minute) { calls += 1; "computed #{calls}" }.should eq("computed 1") }
    calls.should eq(1)
    Caramel::Cache.write("report", "replaced")
    Caramel::Cache.read("report").should eq("replaced")
    ColdBrewSpec.scalar("SELECT expires_at IS NULL AS value FROM caramel_cache WHERE key = 'report'", as: Bool).should be_true
    Caramel::Cache.delete("report").should be_true
    Caramel::Cache.delete("report").should be_false
    Caramel::Cache.write("a", "1")
    Caramel::Cache.clear
    Caramel::Cache.read("a").should be_nil
  end
end

describe Caramel::ColdBrew::Scheduler do
  it "lets one process per period run a schedule, and the block commits with the lease" do
    ColdBrewSpec.reset
    runs = 0
    blocking = true
    gate = Channel(Nil).new
    schedule = Brew::Schedule.new(1.hour, "digest", -> do
      runs += 1
      ColdBrewSpec::Record.enqueue(label: "digest #{runs}")
      gate.receive if blocking
      nil
    end)
    other = Caramel::Database.open(ColdBrewSpec.runtime_url, 2)
    begin
      first = Brew::Scheduler.new([schedule], ColdBrewSpec.runtime)
      second = Brew::Scheduler.new([schedule], other)
      result = Channel(Bool).new(1)
      spawn { result.send(first.run_due(schedule)) }
      ColdBrewSpec.eventually { runs == 1 }
      second.run_due(schedule).should be_false
      blocking = false
      gate.send(nil)
      result.receive.should be_true
      second.run_due(schedule).should be_false
      ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_jobs", as: Int64).should eq(1)
      ColdBrewSpec.owner.exec("UPDATE caramel_schedules SET last_run_at = last_run_at - interval '61 minutes'")
      second.run_due(schedule).should be_true
      runs.should eq(2)
      ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_jobs", as: Int64).should eq(2)
    ensure
      other.close
    end
  end

  it "rolls the lease back with a block that raises" do
    ColdBrewSpec.reset
    attempts = 0
    schedule = Brew::Schedule.new(1.hour, "flaky", -> do
      attempts += 1
      ColdBrewSpec::Record.enqueue(label: "attempt #{attempts}")
      raise "broken" if attempts == 1
      nil
    end)
    scheduler = Brew::Scheduler.new([schedule], ColdBrewSpec.runtime)
    expect_raises(Exception, "broken") { scheduler.run_due(schedule) }
    ColdBrewSpec.scalar("SELECT count(*) AS value FROM caramel_schedules", as: Int64).should eq(0)
    scheduler.run_due(schedule).should be_true
    SugarORM.sql(ColdBrewSpec.owner, "SELECT payload->>'label' AS label FROM caramel_jobs", as: {label: String}).map(&.[:label]).should eq(["attempt 2"])
  end

  it "ticks from fibers in two processes and runs a new schedule once" do
    ColdBrewSpec.reset
    runs = Atomic(Int32).new(0)
    schedule = Brew::Schedule.new(1.hour, "hourly", -> { runs.add(1); nil })
    other = Caramel::Database.open(ColdBrewSpec.runtime_url, 2)
    first = Brew::Scheduler.new([schedule], ColdBrewSpec.runtime).start
    second = Brew::Scheduler.new([schedule], other).start
    begin
      ColdBrewSpec.eventually { runs.get == 1 }
      sleep 300.milliseconds
      runs.get.should eq(1)
    ensure
      first.stop
      second.stop
      other.close
    end
  end
end

describe "Caramel::ColdBrew PubSub" do
  it "delivers a publish only when its transaction commits" do
    ColdBrewSpec.reset
    ColdBrewSpec.with_broker do
      updates = Channel(String).new(8)
      Brew.subscribe("board_1", updates)
      SugarORM::Repo.transaction do
        Brew.publish("board_1", "rolled back")
        SugarORM::Repo.rollback
      end
      SugarORM::Repo.transaction do
        Brew.publish("board_1", "committed")
        ColdBrewSpec.receive?(updates, 300.milliseconds).should be_nil
      end
      ColdBrewSpec.receive?(updates, 5.seconds).should eq("committed")
      ColdBrewSpec.receive?(updates, 300.milliseconds).should be_nil
    end
  end

  it "delivers a job's publish when the drain commits the job" do
    ColdBrewSpec.reset
    ColdBrewSpec.with_broker do
      Brew.subscribe("board_5") do |updates|
        ColdBrewSpec::Announce.enqueue(board: 5)
        ColdBrewSpec.receive?(updates, 300.milliseconds).should be_nil
        Brew.drain_queue!(ColdBrewSpec.runtime).should eq(1)
        ColdBrewSpec.receive?(updates, 5.seconds).should eq("job finished")
      end
    end
  end

  it "never lets a subscriber that does not receive hold up the others" do
    ColdBrewSpec.reset
    ColdBrewSpec.with_broker do
      stuck = Channel(String).new
      live = Channel(String).new(8)
      Brew.subscribe("board_2", stuck)
      Brew.subscribe("board_2", live)
      started = Time.instant
      Brew.publish("board_2", "one")
      Brew.publish("board_2", "two")
      [ColdBrewSpec.receive?(live, 5.seconds), ColdBrewSpec.receive?(live, 5.seconds)].should eq(["one", "two"])
      (Time.instant - started).should be < 900.milliseconds
      sleep 1.2.seconds
      # "one" waited its second and was dropped; "two" is next, in order.
      ColdBrewSpec.receive?(stuck, 500.milliseconds).should eq("two")
      ColdBrewSpec.receive?(stuck, 100.milliseconds).should be_nil
    end
  end

  it "delivers a burst to each subscriber in publish order" do
    ColdBrewSpec.reset
    ColdBrewSpec.with_broker do
      eager = Channel(String).new(3000)
      Brew.subscribe("board_6", eager)
      Brew.subscribe("board_6") do |unbuffered|
        SugarORM::Repo.transaction do
          (1..2000).each { |index| Brew.publish("board_6", index.to_s) }
        end
        Array.new(2000) { ColdBrewSpec.receive?(unbuffered, 5.seconds) }.should eq((1..2000).map(&.to_s))
      end
      Array.new(2000) { ColdBrewSpec.receive?(eager, 5.seconds) }.should eq((1..2000).map(&.to_s))
    end
  end

  it "reconnects and LISTENs again after its connection drops" do
    ColdBrewSpec.reset
    ColdBrewSpec.with_broker do |broker|
      updates = Channel(String).new(8)
      Brew.subscribe("board_4", updates)
      pid = broker.pid.not_nil!
      admin = Caramel::Database.open(COLD_BREW_ADMIN_URL, 1)
      begin
        admin.scalar("SELECT pg_terminate_backend($1)", pid).should be_true
      ensure
        admin.close
      end
      ColdBrewSpec.eventually { (current = broker.pid) && current != pid }
      Brew.publish("board_4", "after reconnect")
      ColdBrewSpec.receive?(updates, 5.seconds).should eq("after reconnect")
    end
  end

  it "streams the RFC-0003 §2.3 action as server-sent events" do
    ColdBrewSpec.reset
    ColdBrewSpec.with_broker do
      app = Caramel::Application.new(ColdBrewSpec::AppRouter.new, Caramel::CSRF.new(Random::Secure.hex(32), "https://brew.test"))
      response = app.handle(HTTP::Request.new("GET", "/boards/7/live", HTTP::Headers{"Host" => "brew.test"}))
      response.status.should eq(200)
      response.headers["Content-Type"].should eq("text/event-stream")
      reader, writer = IO.pipe
      spawn do
        response.streamer.not_nil!.call(writer)
      rescue IO::Error
        # The reader closed: the client went away.
      end
      Brew.publish("board_7", %({"card":1}))
      Brew.publish("board_7", %({"card":2}))
      lines = Array.new(6) { reader.gets(chomp: true) }
      lines.should eq(["event: BoardUpdated", %(data: {"card":1}), "", "event: BoardUpdated", %(data: {"card":2}), ""])
      reader.close
    end
  end
end

describe "Caramel::ColdBrew.start" do
  it "runs a worker per configured queue with the configured concurrency and stops gracefully" do
    ColdBrewSpec.reset
    service = Brew.start(ColdBrewSpec.runtime_url, {"CARAMEL_WORKER_QUEUES" => "default, busy", "CARAMEL_WORKER_CONCURRENCY" => "2"})
    begin
      service.workers.map { |worker| {worker.queue, worker.concurrency} }.should eq([{"default", 2}, {"busy", 2}])
      Brew.broker?.should be(service.broker)
      ColdBrewSpec::Record.enqueue(label: "from default")
      ColdBrewSpec::Busy.enqueue(label: "from busy")
      ColdBrewSpec.eventually { ColdBrewSpec.labels.sort == ["from busy", "from default"] }
    ensure
      service.stop
    end
    Brew.broker?.should be_nil
  end

  it "leaves schedules to other processes when its scheduler is off" do
    ColdBrewSpec.reset
    env = {"CARAMEL_WORKER_QUEUES" => "default"}
    service = Brew.start(ColdBrewSpec.runtime_url, env, scheduler: false)
    begin
      sleep 300.milliseconds
      ColdBrewSpec.schedule_count.should eq(0)
    ensure
      service.stop
    end

    service = Brew.start(ColdBrewSpec.runtime_url, env)
    begin
      ColdBrewSpec.eventually { ColdBrewSpec.schedule_count == 1 }
    ensure
      service.stop
    end
  end
end

describe "the work command" do
  it "runs workers without HTTP until stopped, then lets the in-flight job finish" do
    ColdBrewSpec.reset
    running = ColdBrewSpec::Gated.enqueue(label: "worked")
    url = ColdBrewSpec.runtime_url
    options = Caramel::CommandLine::WorkOptions.new("gated", "1", false)
    stop = Channel(Nil).new
    output = IO::Memory.new
    result = Channel(Int32).new(1)
    spawn { result.send(Caramel::CommandLine.work("Brew", url, options, stop, output)) }

    ColdBrewSpec.eventually { output.to_s.includes?("ready") }
    ready = "Brew worker is ready: queues gated; concurrency 1; scheduler off\n"
    output.to_s.should eq(ready)
    ColdBrewSpec.eventually { !ColdBrewSpec.job(running)[:locked_at].nil? }

    stop.close
    select
    when result.receive
      fail "work returned before its in-flight job finished"
    when timeout(200.milliseconds)
    end
    ColdBrewSpec.gate.send(nil)
    result.receive.should eq(0)
    ColdBrewSpec.job(running)[:finished_at].should_not be_nil
    ColdBrewSpec.labels.should eq(["worked"])
    ColdBrewSpec.schedule_count.should eq(0)
  end
end
