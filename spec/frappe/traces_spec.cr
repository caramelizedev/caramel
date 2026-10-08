require "spec"
require "./support/events"
require "../../src/frappe/traces"

private def error_trace(id : String, at : String) : Caramel::Crema::TraceEvent
  event = EventFixtures.trace("GET /books/:id", id, at, failing: true)
  event
end

private def repeated_trace : Caramel::Crema::TraceEvent
  event = EventFixtures.trace("GET /books", "c" * 32, "2026-10-03T12:00:04.000Z")
  sql = %(SELECT "authors".* FROM "authors" WHERE "id" = $1)
  event.repeated = [Caramel::Crema::RepeatEvent.new(sql, 25, "app/views/books/index.cr:8:5")]
  event
end

private def store_with(*events : Caramel::Crema::TraceEvent) : Caramel::Frappe::EventStore
  store = Caramel::Frappe::EventStore.new
  events.each { |event| store.add(event) }
  store
end

describe Caramel::Frappe::Traces do
  it "prints runtime errors and repeated queries as MRDP, and exits 1" do
    first = error_trace("9f2c4e1a7b3d" + "0" * 20, "2026-10-03T12:00:01.000Z")
    store = store_with(first,
      error_trace("9f2c4e1a7b3e" + "0" * 20, "2026-10-03T12:00:02.000Z"),
      error_trace("9f2c4e1a7b3f" + "0" * 20, "2026-10-03T12:00:03.000Z"),
      repeated_trace)
    output = IO::Memory.new
    status = Caramel::Frappe::Traces.new(store, "/proj", output).errors(agent: true)
    status.should eq(1)
    output.to_s.should eq(<<-TEXT)
      ERR RUNTIME:500 at app/actions/books/show.cr:12:7 | GET /books/:id
      MSG: KeyError: Missing hash key: "title" (3 times, last 12:00:03)
      FIX: frappe trace 9f2c4e1a7b3d --md shows the request, its queries and the backtrace
      ERR REPEATED_QUERY at app/views/books/index.cr:8:5 | GET /books
      MSG: SELECT authors ran 25 times in one request
      FIX: preload the association in the query that loads the records, e.g. .preload(:author)

      TEXT
  end

  it "ends the trace list with the number printed" do
    store = store_with(EventFixtures.trace("GET /", "1" * 32),
      EventFixtures.trace("GET /books", "2" * 32, "2026-10-03T12:00:01.000Z"))
    output = IO::Memory.new
    Caramel::Frappe::Traces.new(store, "/proj", output).list(agent: true)
    output.to_s.lines.last.should eq("OK traces 2")
    output.to_s.lines.first.should start_with("request GET /books")
  end

  it "answers a fingerprint or trace id prefix and refuses an unknown reference" do
    store = store_with(error_trace("1" * 32, "2026-10-03T12:00:01.000Z"))
    output = IO::Memory.new
    traces = Caramel::Frappe::Traces.new(store, "/proj", output)
    traces.show("9f2c4e1a7b3d", markdown: true).should be_true
    output.to_s.should contain("## Backtrace")
    traces.show("nomatch1", markdown: false).should be_false
  end

  it "points a standalone error at a reference frappe trace answers" do
    store = Caramel::Frappe::EventStore.new
    store.add(EventFixtures.error("abcdef012345"))
    output = IO::Memory.new
    traces = Caramel::Frappe::Traces.new(store, "/proj", output)
    traces.errors(agent: true)
    output.to_s.should contain(
      "FIX: frappe trace abcdef012345 --md shows the error and its backtrace")
    output.clear
    traces.show("abcdef", markdown: true).should be_true
    output.to_s.should contain("# KeyError")
    output.to_s.should contain("## Backtrace")
    output.clear
    traces.show("abcdef", markdown: false).should be_true
    output.to_s.should contain("error KeyError fingerprint=abcdef012345")
    output.to_s.should contain("Missing hash key")
    traces.show("abcde", markdown: false).should be_false
  end

  it "says so when nothing went wrong" do
    output = IO::Memory.new
    traces = Caramel::Frappe::Traces.new(Caramel::Frappe::EventStore.new, "/proj", output)
    status = traces.errors(agent: true)
    status.should eq(0)
    output.to_s.should eq("OK errors 0\n")
  end

  it "ignores errors from before the newest successful build" do
    store = store_with(error_trace("1" * 32, "2026-10-03T12:00:01.000Z"))
    store.add(Caramel::Crema::BuildEvent.new("2026-10-03T12:00:10.000Z", "built", 800.0))
    output = IO::Memory.new
    Caramel::Frappe::Traces.new(store, "/proj", output).errors(agent: true).should eq(0)
    output.to_s.should eq("OK errors 0\n")

    store.add(error_trace("2" * 32, "2026-10-03T12:00:20.000Z"))
    output = IO::Memory.new
    Caramel::Frappe::Traces.new(store, "/proj", output).errors(agent: true).should eq(1)
  end

  it "keeps errors when the newest build failed" do
    store = store_with(error_trace("1" * 32, "2026-10-03T12:00:01.000Z"))
    store.add(Caramel::Crema::BuildEvent.new("2026-10-03T12:00:10.000Z", "failed", 800.0))
    output = IO::Memory.new
    Caramel::Frappe::Traces.new(store, "/proj", output).errors(agent: true).should eq(1)
  end
end
