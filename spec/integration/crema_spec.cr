require "spec"
require "random/secure"
require "../../src/caramel"
require "../../src/caramel/crema/recorder"

private def owned_url(variable : String, missing : String) : String
  ENV[variable]? || raise "Run scripts/check integration; no #{missing} provided"
end

private CREMA_ADMIN_URL   = owned_url("CARAMEL_OWNED_ADMIN_URL", "owned admin connection")
private CREMA_OWNER_URL   = owned_url("CARAMEL_OWNED_SPEC_URL", "owned test database")
private CREMA_RUNTIME_URL = owned_url("CARAMEL_OWNED_MODEL_RUNTIME_URL", "runtime role URL")

module CremaSpec
  alias Trace = Caramel::Crema::TraceEvent

  # Keeps every finished trace in development detail.
  class CaptureSink < Caramel::Crema::Sink
    getter events = [] of Trace

    def name : String
      "capture"
    end

    def records?(trace : Caramel::Crema::Trace) : Bool
      true
    end

    def finished(trace : Caramel::Crema::Trace) : Nil
      @events << trace.to_event(Caramel::Crema::Detail::Development)
    end
  end

  struct Notify < Caramel::ColdBrew::Job
    queue "crema"

    def perform
      SugarORM.sql_exec("SELECT 1")
    end
  end

  struct Explode < Caramel::ColdBrew::Job
    queue "crema"

    def perform
      raise KeyError.new("job detail")
    end
  end

  abstract struct Page < Caramel::Action
    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  struct Show < Page
    contract do
      field id : Int64
    end

    def handle(contract : Contract) : Caramel::Response
      2.times { SugarORM.sql("SELECT 1 AS n", as: {n: Int32}) }
      Notify.enqueue
      Caramel::Response.new(body: "shown")
    end
  end

  struct Repeats < Page
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      6.times { SugarORM.sql("SELECT $1::int AS n", 1, as: {n: Int32}) }
      Caramel::Response.new(body: "repeated")
    end
  end

  struct Tagged < Page
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      sql = "SELECT query FROM pg_stat_activity WHERE pid = pg_backend_pid()"
      Caramel::Response.new(body: SugarORM.sql(sql, as: {query: String}).first[:query])
    end
  end

  struct Flaky < Page
    contract do
      field fail : Int32?
    end

    def handle(contract : Contract) : Caramel::Response
      SugarORM.sql("SELECT $1::int AS n", 1, as: {n: Int32})
      raise KeyError.new("secret detail of the failure") if contract.fail == 1
      Caramel::Response.new(body: "fine")
    end
  end

  Caramel::Router.draw do
    get "/books/:id", CremaSpec::Show
    get "/repeats", CremaSpec::Repeats
    get "/tagged", CremaSpec::Tagged
    get "/flaky", CremaSpec::Flaky
  end

  NAME = "caramel_crema_#{Random::Secure.hex(6)}"

  @@owner : DB::Database? = nil
  @@runtime : DB::Database? = nil

  def self.url(base : String) : String
    base.sub("/caramel_spec?", "/#{NAME}?")
  end

  # A scratch database the spec role migrates, as a Latte migration role would.
  def self.owner : DB::Database
    @@owner ||= begin
      admin = Caramel::Database.open(CREMA_ADMIN_URL, 1)
      begin
        admin.exec(%(CREATE DATABASE "#{NAME}" OWNER caramel_spec))
        admin.exec(%(REVOKE CONNECT, TEMPORARY ON DATABASE "#{NAME}" FROM PUBLIC))
        admin.exec(%(GRANT CONNECT ON DATABASE "#{NAME}" TO caramel_spec, caramel_model_spec))
      ensure
        admin.close
      end
      owner = Caramel::Database.open(url(CREMA_OWNER_URL), 4)
      owner.exec("REVOKE ALL ON SCHEMA public FROM PUBLIC")
      owner.exec("GRANT USAGE ON SCHEMA public TO caramel_model_spec")
      owner.exec("ALTER DEFAULT PRIVILEGES IN SCHEMA public " \
                 "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO caramel_model_spec")
      owner.exec("ALTER DEFAULT PRIVILEGES IN SCHEMA public " \
                 "GRANT USAGE, SELECT ON SEQUENCES TO caramel_model_spec")
      SugarORM::Migrator.new(owner, Caramel::ColdBrew::MIGRATIONS).migrate
      owner
    end
  end

  def self.runtime : DB::Database
    @@runtime ||= Caramel::Database.open(url(CREMA_RUNTIME_URL), 8)
  end

  def self.runtime_url : String
    url(CREMA_RUNTIME_URL)
  end

  def self.reset : DB::Database
    owner.exec("TRUNCATE caramel_jobs, caramel_metrics")
    SugarORM::Repo.database = runtime
  end

  def self.drop : Nil
    return unless @@owner
    @@runtime.try(&.close)
    @@owner.try(&.close)
    admin = Caramel::Database.open(CREMA_ADMIN_URL, 1)
    admin.exec(%(DROP DATABASE IF EXISTS "#{NAME}" WITH (FORCE)))
    admin.close
  end

  def self.application : Caramel::Application
    csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
    Caramel::Application.new(AppRouter.new, csrf)
  end

  def self.get(path : String) : Caramel::Response
    headers = HTTP::Headers{"Host" => "bookshelf.caramel"}
    application.handle(HTTP::Request.new("GET", path, headers))
  end

  # The traces finished while the block ran.
  def self.capturing(& : ->) : Array(Trace)
    sink = CaptureSink.new
    Caramel::Crema.subscribe(sink)
    begin
      yield
    ensure
      Caramel::Crema.unsubscribe(sink)
    end
    sink.events
  end

  def self.drain : Int32
    Caramel::ColdBrew.drain_queue(runtime, "crema")
  end
end

Spec.after_suite { CremaSpec.drop }

describe "Crema instrumentation" do
  it "counts a request's queries, including the enqueue's insert" do
    CremaSpec.reset
    events = CremaSpec.capturing { CremaSpec.get("/books/7") }
    request = events.find! { |event| event.kind == "request" }
    request.name.should eq("GET /books/:id")
    request.db_count.should eq(3)
    request.enqueued.should eq(1)
    request.spans.count { |span| span.kind == "enqueue" }.should eq(1)
  end

  it "runs an enqueued job in the request's trace" do
    CremaSpec.reset
    events = CremaSpec.capturing do
      CremaSpec.get("/books/7")
      CremaSpec.drain.should eq(1)
    end
    request = events.find! { |event| event.kind == "request" }
    job = events.find! { |event| event.kind == "job" }
    job.trace_id.should eq(request.trace_id)
    job.parent_id.should eq(request.span_id)
    job.request_id.should eq(request.request_id)
    job.name.should eq("CremaSpec::Notify")
    job.queue.should eq("crema")
    job.queue_lag_ms.not_nil!.should be >= 0
  end

  it "ends a failing job's trace in error with the exception's class" do
    CremaSpec.reset
    CremaSpec::Explode.enqueue
    events = CremaSpec.capturing { CremaSpec.drain }
    job = events.find! { |event| event.kind == "job" }
    job.outcome.should eq("error")
    job.error.not_nil!.error_class.should eq("KeyError")
  end

  it "reports a statement repeated within a request once, with its count" do
    CremaSpec.reset
    events = CremaSpec.capturing { CremaSpec.get("/repeats") }
    repeated = events.find! { |event| event.kind == "request" }.repeated
    repeated.size.should eq(1)
    repeated.first.count.should eq(6)
    repeated.first.sql.should eq("SELECT $1::int AS n")
  end

  it "tags a request's statements with its action for PostgreSQL" do
    CremaSpec.reset
    CremaSpec.get("/tagged").body.should start_with("/*action='")
  end

  it "leaves a statement outside any trace untagged" do
    CremaSpec.reset
    sql = "SELECT query FROM pg_stat_activity WHERE pid = pg_backend_pid()"
    SugarORM.sql(sql, as: {query: String}).first[:query].should start_with("SELECT query")
  end

  it "names a pool's backends in pg_stat_activity" do
    CremaSpec.reset
    db = Caramel::Database.open(CremaSpec.runtime_url, 2, application_name: "caramel-spec")
    begin
      sql = "SELECT application_name FROM pg_stat_activity WHERE pid = pg_backend_pid()"
      db.scalar(sql).should eq("caramel-spec")
    ensure
      db.close
    end
  end
end

describe "Crema job commands" do
  it "classifies a queue's jobs as ColdBrew.statuses does" do
    CremaSpec.reset
    owner = CremaSpec.owner
    queued = CremaSpec::Notify.enqueue
    scheduled = CremaSpec::Notify.enqueue(run_at: 1.hour.from_now)
    running = CremaSpec::Notify.enqueue
    retrying = CremaSpec::Notify.enqueue
    failed = CremaSpec::Notify.enqueue
    owner.exec("UPDATE caramel_jobs SET locked_at = now() WHERE id = $1", running)
    owner.exec("UPDATE caramel_jobs SET attempts = 1 WHERE id = $1", retrying)
    owner.exec("UPDATE caramel_jobs SET failed_at = now() WHERE id = $1", failed)

    row = Caramel::Crema::Jobs.stats(CremaSpec.runtime).rows.find! { |cells| cells[0] == "crema" }
    row[1..6].should eq(["1", "1", "1", "1", "1", "0"])
    ids = [queued, scheduled, running, retrying, failed]
    states = Caramel::ColdBrew.statuses(CremaSpec.runtime, ids)
    states.values.map(&.state.to_s).sort!.should eq(%w[Failed Queued Retrying Running Scheduled])
  end

  it "lists failed jobs by class and error, and shows one in full" do
    CremaSpec.reset
    id = CremaSpec::Notify.enqueue
    CremaSpec.owner.exec("UPDATE caramel_jobs SET failed_at = now(), last_error = $2 WHERE id = $1",
      id, "KeyError: missing key")
    failed = Caramel::Crema::Jobs.failed(20, CremaSpec.runtime)
    failed.rows.first.first(3).should eq(["CremaSpec::Notify", "KeyError", "1"])
    shown = Caramel::Crema::Jobs.show(id, CremaSpec.runtime)
    shown.rows.first[shown.headers.index!("last_error")].should eq("KeyError: missing key")
  end

  it "retries a failed job once, by id or by class" do
    CremaSpec.reset
    id = CremaSpec::Notify.enqueue
    sql = "UPDATE caramel_jobs SET failed_at = now(), attempts = 5 WHERE id = $1"
    CremaSpec.owner.exec(sql, id)
    Caramel::Crema::Jobs.retry_class("Other", CremaSpec.runtime).should eq(0)
    Caramel::Crema::Jobs.retry_id(id, CremaSpec.runtime).should eq(1)
    CremaSpec.drain.should eq(1)
    Caramel::ColdBrew.status(CremaSpec.runtime, id).not_nil!.state
      .should eq(Caramel::ColdBrew::JobState::Finished)
    Caramel::Crema::Jobs.retry_id(id, CremaSpec.runtime).should eq(0)
  end
end

describe "Crema db diagnose" do
  it "prints every section under its header and the pg_stat_statements hint" do
    CremaSpec.reset
    ok = false
    output = String.build { |io| ok = Caramel::Crema::Diagnose.run(io, CremaSpec.runtime) }
    ok.should be_true
    %w[connections long_running blocking cache_hit seq_scans unused_indexes vacuum table_sizes
      outliers].each { |name| output.should contain("== #{name} ==") }
    output.should_not contain(": unavailable (")
    output.should contain("outliers: pg_stat_statements is not installed in this database.")
  end
end

describe Caramel::Crema::Recorder do
  it "normalizes SQL keys: literals, numbers and IN lists become ?, identifiers stay" do
    key = ->(sql : String) { Caramel::Crema::Recorder.sql_key(sql) }
    key.call("SELECT * FROM table1 WHERE id = 42 AND name = 'it''s'")
      .should eq("SELECT * FROM table1 WHERE id = ? AND name = ?")
    key.call("SELECT $1::int, x2 FROM t WHERE id IN (1, 2, 3)")
      .should eq("SELECT $1::int, x2 FROM t WHERE id IN (?)")
    key.call("WHERE id IN ($1, $2, $3)").should eq("WHERE id IN (?)")
    key.call("SELECT\n  1\u0000 FROM t").should eq("SELECT ? FROM t")
    key.call("SELECT " + "x" * 800).bytesize.should eq(Caramel::Crema::Recorder::MAX_SQL_KEY)
  end

  it "keeps per-minute aggregates, never a message, and adds to a row it wrote" do
    CremaSpec.reset
    recorder = Caramel::Crema::Recorder.new(CremaSpec.runtime)
    Caramel::Crema.subscribe(recorder)
    minute = Time.utc.at_beginning_of_minute
    begin
      CremaSpec.get("/flaky")
      CremaSpec.get("/flaky?fail=1")
      recorder.flush(minute)
      CremaSpec.get("/flaky")
      recorder.flush(minute)
    ensure
      Caramel::Crema.unsubscribe(recorder)
    end
    owner = CremaSpec.owner
    rows = "SELECT count, errors, array_length(histogram, 1), " \
           "(SELECT sum(n) FROM unnest(histogram) AS n)::int FROM caramel_metrics " \
           "WHERE kind = 'request' AND key = 'GET /flaky'"
    owner.query_all(rows, as: {Int64, Int64, Int32, Int32}).should eq([{3_i64, 1_i64, 12, 3}])
    statement = "SELECT count(*) FROM caramel_metrics WHERE kind = 'sql' " \
                "AND key = 'SELECT $1::int AS n'"
    owner.scalar(statement).as(Int64).should be >= 1
    leaked = "SELECT count(*) FROM caramel_metrics " \
             "WHERE caramel_metrics::text LIKE '%secret detail%'"
    owner.scalar(leaked).as(Int64).should eq(0)
  end

  it "reports the busiest routes through insights" do
    CremaSpec.reset
    recorder = Caramel::Crema::Recorder.new(CremaSpec.runtime)
    Caramel::Crema.subscribe(recorder)
    begin
      3.times { CremaSpec.get("/flaky") }
      recorder.flush
    ensure
      Caramel::Crema.unsubscribe(recorder)
    end
    table = Caramel::Crema::Insights.table("request", 1.hour, CremaSpec.runtime)
    table.headers.should eq(%w[KEY COUNT ERR P50MS P95MS MAXMS TOTAL_S])
    table.rows.first[0, 3].should eq(["GET /flaky", "3", "0"])
    Caramel::Crema::Insights.duration("90m").should eq(90.minutes)
    Caramel::Crema::Insights.duration("soon").should be_nil
  end

  it "loses a batch it cannot write, logs a warning and raises nothing" do
    CremaSpec.reset
    recorder = Caramel::Crema::Recorder.new(CremaSpec.runtime)
    Caramel::Crema.subscribe(recorder)
    begin
      CremaSpec.get("/flaky")
    ensure
      Caramel::Crema.unsubscribe(recorder)
    end
    before = Caramel::Crema.dropped["recorder"]? || 0_i64
    CremaSpec.owner.exec("ALTER TABLE caramel_metrics RENAME TO caramel_metrics_away")
    begin
      Log.capture("crema") do |logs|
        recorder.flush
        logs.check(:warn, /\Arecorder flush failed error_type=/)
      end
    ensure
      CremaSpec.owner.exec("ALTER TABLE caramel_metrics_away RENAME TO caramel_metrics")
    end
    (Caramel::Crema.dropped["recorder"]? || 0_i64).should be > before
  end
end
