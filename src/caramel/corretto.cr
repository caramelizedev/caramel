require "spec"
require "http/client"
require "socket"
require "../caramel"
require "./outbound"
require "./corretto/worker"
require "./corretto/wire"
require "./corretto/client"
require "./corretto/matchers"

# Corretto (RFC-0006): zero-mock integration testing. Specs require
# "caramel/corretto" and call `Corretto.configure` once in spec/spec_helper.cr;
# `frappe corretto` runs them against per-worker Latte clones of the migrated
# spec database.
module Corretto
  WORKER_DATABASE = /\Acaramel_spec_[0-9a-f]{16}_w[1-9][0-9]?\z/

  class Config
    property database_url : String? = nil
    property migration_url : String? = nil
    property application : Proc(DB::Database, Caramel::Application)? = nil
  end

  @@worker : Worker? = nil
  @@build : Proc(DB::Database, Caramel::Application)? = nil
  @@application : {DB::Database, Caramel::Application}? = nil
  @@wire : Wire? = nil

  # The generated spec/spec_helper.cr's configuration: this worker's Latte
  # spec databases, and the application built on the spec pool. Call it from
  # spec/: its __DIR__ locates the project.
  def self.configure(app : T.class, source : String = __DIR__) : Nil forall T
    root = File.expand_path("..", source)
    configure do |config|
      config.database_url = Caramel::Database.url
      config.migration_url = Caramel::Database.url(migration: true)
      config.application = ->(db : DB::Database) { Caramel.build(app, db, ENV["APP_SECRET"], ENV["APP_ORIGIN"], root) }
    end
  end

  # Verifies that this process runs under `frappe corretto` against its own
  # worker database, then installs the per-example isolation and the wire proxy.
  # ameba:disable Metrics/CyclomaticComplexity -- checks each worker precondition before specs run
  def self.configure(& : Config ->) : Nil
    raise Error.new("Corretto.configure runs once, in spec/spec_helper.cr") if @@worker
    index = ENV["CORRETTO_WORKER"]?
    abort("Run these specs with frappe corretto") unless ENV["CARAMEL_ENV"]? == "test" && index
    config = Config.new
    yield config
    runtime_url = config.database_url || raise Error.new("Set config.database_url (Caramel::Database.url) in Corretto.configure")
    migration_url = config.migration_url || raise Error.new("Set config.migration_url (Caramel::Database.url(migration: true)) in Corretto.configure")
    build = config.application || raise Error.new("Set config.application = ->(db : DB::Database) { Caramel.build(App, db, …) } in Corretto.configure")
    expected = ENV["CARAMEL_SPEC_DATABASE"]?
    database = Caramel::Database::Config.parse(runtime_url).database
    unless runtime_url == ENV["CARAMEL_EXPECTED_DATABASE_URL"]? && expected && database == expected && database.matches?(WORKER_DATABASE) &&
           Caramel::Database::Config.parse(migration_url).database == database
      abort("Spec database identity differs from this Corretto worker; development data was not touched")
    end
    worker = Worker.new(runtime_url, migration_url, latte_reset(index))
    unless worker.database.query_one("SELECT current_database()", as: String) == expected
      worker.close
      abort("Connected spec database identity differs; development data was not touched")
    end
    @@worker = worker
    @@build = build
    wire
    Spec.around_each do |example|
      item = example.example
      application(worker) # rebinds SugarORM::Repo.database after a reset
      leaked = worker.run(item.all_tags.includes?("catalog")) { example.run }
      if leaked
        STDERR.puts "\nCorretto: #{item.file}:#{item.line} changed the database catalog outside its transaction; worker #{index} was reset from the migrated template. Tag the example `catalog` when it must run DDL."
      end
    ensure
      wire.reset
    end
    Spec.after_suite do
      worker.close
      wire.close
    end
  end

  # Yields a client for the configured application and the example's
  # connection, which in-process requests share.
  def self.session(& : Client, DB::Connection ->) : Nil
    worker = @@worker || raise Error.new("Call Corretto.configure in spec/spec_helper.cr before Corretto.session")
    connection = worker.connection
    yield Client.new(application(worker)), connection
  end

  # Stubs `url` (any method unless `method` is given) at the wire proxy until
  # the example ends.
  def self.stub_wire(url : String, method : String? = nil) : Wire::Stub
    wire.stub(url, method)
  end

  # The outbound requests the wire proxy received in this example, in order.
  def self.wire_requests : Array(Wire::Request)
    wire.requests
  end

  # The suite's wire proxy; starting it points `Caramel::Outbound` at it.
  def self.wire : Wire
    @@wire ||= Wire.new.tap { |proxy| Caramel::Outbound.proxy = proxy.address }
  end

  # The application built on the worker's current database; a Tier 3 reset
  # replaces the database, so the application is rebuilt on it.
  private def self.application(worker : Worker) : Caramel::Application
    current = @@application
    return current[1] if current && current[0].same?(worker.database)
    build = @@build || raise Error.new("Corretto has no application; call Corretto.configure in spec/spec_helper.cr")
    application = build.call(worker.database)
    @@application = {worker.database, application}
    application
  end

  # Asks Latte to replace this worker's database with a fresh clone of the
  # migrated spec template (the endpoint `frappe corretto` created it with).
  private def self.latte_reset(index : String) : Proc(Nil)
    socket = ENV["CORRETTO_LATTE_SOCKET"]? || abort("CORRETTO_LATTE_SOCKET is missing; run these specs with frappe corretto")
    site = ENV["CORRETTO_SITE"]?
    abort("CORRETTO_SITE and CORRETTO_WORKER are invalid; run these specs with frappe corretto") unless site && site.matches?(/\A[0-9a-f]{16}\z/) && index.matches?(/\A[1-9][0-9]?\z/)
    -> do
      UNIXSocket.open(socket) do |io|
        io.read_timeout = 20.seconds
        response = HTTP::Client.new(io, "latte").post("/v1/sites/#{site}/test-workers/#{index}", HTTP::Headers{"Content-Type" => "application/json", "Connection" => "close"}, "{}")
        raise Error.new("Latte could not reset test worker #{index} (#{response.status_code}): #{response.body}") unless response.success?
      end
      nil
    end
  end

  # Mocking is forbidden (RFC-0006 §2.1): refuse to compile a suite that loads a mocking library.
  macro finished
    {% for name in %w[Mocks Mock Double] %}
      {% if @top_level.has_constant?(name) %}
        {% raise "Corretto forbids mocking, but `#{name.id}` from a mocking library is loaded.\nRemediation: remove the mocking shard and its requires; assert on observable ingress, database rows and rendered hypermedia, and fake third parties at the wire with Corretto.stub_wire." %}
      {% end %}
    {% end %}
    {% if @top_level.has_constant?("Spectator") && @top_level.constant("Spectator").has_constant?("Mocks") %}
      {% raise "Corretto forbids mocking, but Spectator::Mocks is loaded.\nRemediation: remove Spectator's mocks; assert on observable ingress, database rows and rendered hypermedia, and fake third parties at the wire with Corretto.stub_wire." %}
    {% end %}
  end
end

include Corretto::Matchers
