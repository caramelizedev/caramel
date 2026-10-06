require "http/server"
require "json"
require "socket"
require "../caramel/crema/event"

module Caramel::Latte
  # A local OTLP/HTTP collector (ADR 0029). Any local process may write traces to
  # `127.0.0.1:4318`, as with any OpenTelemetry collector, and nothing here serves
  # reads: they go through the control API on the owner-only socket. Only JSON is
  # accepted, and only the fields a trace view needs are kept.
  class Collector
    MAX_BODY       = 4 * 1024 * 1024
    MAX_TRACES     = 2000
    MAX_SPANS      =  200
    MAX_ATTRIBUTES =   32
    MAX_VALUE      =  256
    TRACE_ID       = /\A[0-9a-f]{32}\z/
    SPAN_ID        = /\A[0-9a-f]{16}\z/
    DEADLINE       = 10.seconds
    JSON_ONLY      = "{\"error\":\"Latte accepts OTLP/HTTP JSON; " \
                     "set OTEL_EXPORTER_OTLP_PROTOCOL=http/json\"}"

    # One trace as the listing shows it.
    record Summary,
      trace_id : String,
      name : String,
      services : Array(String),
      span_count : Int32,
      started_at : String,
      duration_ms : Float64,
      error : Bool do
      include JSON::Serializable
    end

    # A server that gives each connection a read timeout and a total lifetime, so a
    # client that trickles a request cannot hold a fiber. The timer ends with the
    # connection.
    private class BoundedServer < HTTP::Server
      protected def dispatch(io)
        done = Channel(Nil).new
        if socket = io.as?(TCPSocket)
          socket.read_timeout = DEADLINE
          socket.write_timeout = DEADLINE
          spawn(name: "latte:collector:timer") { expire(socket, done) }
        end
        super
      ensure
        done.try(&.close)
      end

      private def expire(socket : TCPSocket, done : Channel(Nil)) : Nil
        select
        when done.receive?
        when timeout(DEADLINE)
          socket.close unless socket.closed?
        end
      rescue IO::Error
      end
    end

    private class Trace
      getter spans = [] of Crema::CollectedSpan
      property dropped = 0
    end

    getter port : Int32
    getter state : String = "stopped"
    getter error : String? = nil
    @server : HTTP::Server? = nil
    @failure_logged = false

    def initialize(@port : Int32 = 4318)
      @lock = Mutex.new
      @traces = {} of String => Trace
    end

    # Binds the port on loopback. A port in use leaves the collector `unavailable`
    # and the daemon running.
    def start : Nil
      server = BoundedServer.new { |context| handle(context) }
      server.max_request_line_size = 2048
      server.max_headers_size = 16 * 1024
      server.bind_tcp("127.0.0.1", @port)
      @server = server
      @state = "running"
      spawn(name: "latte:collector") { server.listen }
    rescue Socket::BindError
      @state = "unavailable"
      @error = "port #{@port} is in use"
    end

    def stop : Nil
      @server.try { |server| server.close unless server.closed? }
      @server = nil
      @state = "stopped"
    end

    # The newest *limit* traces first.
    def traces(limit : Int32 = 50) : Array(Summary)
      @lock.synchronize do
        @traces.to_a.reverse.first(limit).map { |id, trace| summarize(id, trace) }
      end
    end

    # The spans of *trace_id*, or nil when none arrived.
    def spans(trace_id : String) : Array(Crema::CollectedSpan)?
      @lock.synchronize { @traces[trace_id]?.try(&.spans.dup) }
    end

    # How many spans past 200 per trace were dropped.
    def dropped : Int32
      @lock.synchronize { @traces.sum(0) { |_, trace| trace.dropped } }
    end

    # Stores every span in an OTLP JSON *body*. The whole document is read before any
    # span is stored, so a malformed one stores nothing.
    # A body that is valid JSON but not an object is as malformed as one that does not parse.
    def ingest(body : String) : Nil
      collected = [] of {String, Crema::CollectedSpan}
      document = JSON.parse(body).as_h? || raise JSON::ParseException.new("not an object", 1, 1)
      (document["resourceSpans"]?.try(&.as_a?) || [] of JSON::Any).each do |resource|
        collect_resource(resource, collected)
      end
      collected.each { |trace_id, span| store(trace_id, span) }
    end

    private def handle(context : HTTP::Server::Context) : Nil
      request = context.request
      response = context.response
      unless request.method == "POST" && request.path == "/v1/traces"
        return answer(response, 404, %({"error":"not found"}))
      end
      type = request.headers["Content-Type"]?.try(&.split(';').first.strip.downcase)
      return answer(response, 415, JSON_ONLY) unless type.try(&.starts_with?("application/json"))

      body = read_body(request) || return answer(response, 413, %({"error":"body too large"}))
      ingest(body)
      answer(response, 200, "{}")
    rescue JSON::ParseException
      answer(context.response, 400, %({"error":"malformed OTLP JSON"}))
    rescue error
      # Parsing guards every shape an exporter can send, so this is a collector bug: say so
      # once on stderr (the daemon log) and answer 500, not a misleading 400.
      STDERR.puts("Latte collector failed: #{error.class}") unless @failure_logged
      @failure_logged = true
      answer(context.response, 500, %({"error":"collector failed"}))
    end

    # Every answer closes the connection, so an exporter never holds one the server will
    # drop on its own.
    private def answer(response : HTTP::Server::Response, status : Int32, body : String) : Nil
      response.status_code = status
      response.headers["Connection"] = "close"
      response.content_type = "application/json"
      response.print(body)
    end

    # The body, or nil when it exceeds MAX_BODY.
    private def read_body(request : HTTP::Request) : String?
      length = request.headers["Content-Length"]?.try(&.to_i64?)
      if length && length > MAX_BODY
        discard(request, length)
        return
      end

      io = request.body || return ""
      buffer = IO::Memory.new
      IO.copy(io, buffer, MAX_BODY + 1)
      buffer.size > MAX_BODY ? nil : buffer.to_s
    end

    # Reads past a refused body of up to four times MAX_BODY, so an honest exporter sees
    # the 413 and not a broken pipe.
    private def discard(request : HTTP::Request, length : Int64) : Nil
      return if length > 4 * MAX_BODY

      request.body.try(&.skip(length))
    rescue IO::Error
      nil
    end

    private def collect_resource(
      resource : JSON::Any,
      into : Array({String, Crema::CollectedSpan}),
    ) : Nil
      fields = resource.as_h? || return
      service = service_of(fields)
      (fields["scopeSpans"]?.try(&.as_a?) || [] of JSON::Any).each do |scope|
        spans = scope.as_h?.try(&.["spans"]?).try(&.as_a?) || next
        spans.each do |entry|
          span = entry.as_h? || next
          trace_id = span["traceId"]?.try(&.as_s?) || next
          next unless trace_id.matches?(TRACE_ID)

          collected = parse(service, span) || next
          into << {trace_id, collected}
        end
      end
    end

    private def service_of(resource : Hash(String, JSON::Any)) : String
      attributes = resource["resource"]?.try(&.as_h?).try(&.["attributes"]?).try(&.as_a?)
      found = (attributes || [] of JSON::Any).find do |item|
        item.as_h?.try(&.["key"]?).try(&.as_s?) == "service.name"
      end
      name = found.try(&.as_h?).try(&.["value"]?).try(&.as_h?).try(&.["stringValue"]?)
      clip(name.try(&.as_s?) || "unknown")
    end

    private def store(trace_id : String, collected : Crema::CollectedSpan) : Nil
      @lock.synchronize do
        trace = (@traces[trace_id] ||= Trace.new)
        if trace.spans.size >= MAX_SPANS
          trace.dropped += 1
        else
          trace.spans << collected
        end
        @traces.shift if @traces.size > MAX_TRACES
      end
    end

    private def parse(service : String, span : Hash(String, JSON::Any)) : Crema::CollectedSpan?
      span_id = span["spanId"]?.try(&.as_s?) || return
      return unless span_id.matches?(SPAN_ID)

      parent = span["parentSpanId"]?.try(&.as_s?)
      parent = nil if parent && parent.empty?
      return if parent && !parent.matches?(SPAN_ID)

      started = nanoseconds(span["startTimeUnixNano"]?) || return
      return unless started > 0

      finished = Math.max(nanoseconds(span["endTimeUnixNano"]?) || started, started)
      Crema::CollectedSpan.new(service, span_id, parent, clip(span["name"]?.try(&.as_s?) || ""),
        kind_of(span), started, finished, error_of(span), attributes_of(span))
    end

    private def kind_of(span : Hash(String, JSON::Any)) : Int32
      kind = span["kind"]?.try(&.as_i64?)
      kind && kind >= 0 && kind <= 5 ? kind.to_i : 0
    end

    private def error_of(span : Hash(String, JSON::Any)) : Bool
      span["status"]?.try(&.as_h?).try(&.["code"]?).try(&.as_i64?) == 2
    end

    private def clip(text : String, limit : Int32 = 256) : String
      text.byte_slice(0, limit).scrub
    end

    # OTLP JSON carries 64-bit integers as strings.
    private def nanoseconds(value : JSON::Any?) : Int64?
      value.try { |any| any.as_s?.try(&.to_i64?) || any.as_i64? }
    end

    private def attributes_of(span : Hash(String, JSON::Any)) : Hash(String, String)
      found = {} of String => String
      (span["attributes"]?.try(&.as_a?) || [] of JSON::Any).each do |entry|
        break if found.size >= MAX_ATTRIBUTES

        item = entry.as_h? || next
        key = item["key"]?.try(&.as_s?) || next
        value = scalar(item["value"]?) || next
        found[clip(key)] = value.byte_slice(0, MAX_VALUE).scrub
      end
      found
    end

    private def scalar(value : JSON::Any?) : String?
      hash = value.try(&.as_h?) || return
      raw = hash["stringValue"]? || hash["intValue"]? || hash["doubleValue"]? || hash["boolValue"]?
      raw.try(&.raw.to_s)
    end

    private def summarize(trace_id : String, trace : Trace) : Summary
      spans = trace.spans
      started = spans.min_of(&.start_unix_nano)
      finished = spans.max_of(&.end_unix_nano)
      root = spans.find { |span| span.parent_id.nil? } || spans.first
      Summary.new(trace_id, root.name, spans.map(&.service).uniq!.sort!, spans.size,
        Time.unix_ms(started // 1_000_000).to_utc.to_rfc3339(fraction_digits: 3),
        ((finished - started) / 1_000_000.0).round(3), spans.any?(&.error?))
    end
  end
end
