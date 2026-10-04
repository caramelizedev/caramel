require "spec"
require "random/secure"
require "../../src/caramel"

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

  Caramel::Router.draw do
    get "/books/:id", CremaSpec::Show
    get "/repeats", CremaSpec::Repeats
    get "/tagged", CremaSpec::Tagged
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
    owner.exec("TRUNCATE caramel_jobs")
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
    job.queue_lag_ms.should_not be_nil
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
      db.scalar("SELECT current_setting('application_name')").should eq("caramel-spec")
    ensure
      db.close
    end
  end
end
