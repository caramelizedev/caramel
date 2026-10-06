require "../../../src/caramel/crema/event"

# Builders for the wire-format events specs feed Frappé and the renderers.
module EventFixtures
  alias Crema = Caramel::Crema

  def self.error(fingerprint : String = "9f2c4e1a7b3d", at : String = "2026-10-03T12:00:03.000Z")
    error = Crema::ErrorEvent.new("KeyError", fingerprint, false, at)
    error.location = "app/actions/books/show.cr:12:7"
    error.message = %(Missing hash key: "title")
    error.backtrace = ["lib/x/y.cr:1:1 in 'Hash#fetch'", "app/actions/books/show.cr:12:7 in 'show'"]
    error
  end

  def self.trace(name : String = "GET /books/:id",
                 id : String = "a" * 32,
                 at : String = "2026-10-03T12:00:00.000Z",
                 failing : Bool = false) : Crema::TraceEvent
    event = Crema::TraceEvent.new("request", name, id, "b" * 16, at, 12.4, failing ? "error" : "ok")
    event.request_id = "req-#{id[0, 8]}"
    event.method = name.partition(' ')[0]
    event.route = name.partition(' ')[2]
    event.status = failing ? 500 : 200
    event.db_count = 2
    event.db_ms = 3.5
    if failing
      event.error = error(at: at)
      event.error.try(&.trace_id = id)
    end
    event
  end

  def self.query(sql : String, source : String? = nil) : Crema::SpanEvent
    span = Crema::SpanEvent.new("sql", "SELECT books", 1.0, 0.8)
    span.detail = sql
    span.source = source
    span
  end

  def self.line(event : Crema::TraceEvent | Crema::ErrorEvent | Crema::BuildEvent) : String
    event.to_json
  end
end
