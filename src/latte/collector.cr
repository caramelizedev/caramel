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
    # client that trickles a request cannot hold a fiber.
    private class BoundedServer < HTTP::Server
      protected def dispatch(io)
        if socket = io.as?(TCPSocket)
          socket.read_timeout = DEADLINE
          socket.write_timeout = DEADLINE
          spawn do
            sleep DEADLINE
            socket.close unless socket.closed?
          rescue IO::Error
          end
        end
        super
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

    # Stores every span in an OTLP JSON *body*.
    def ingest(body : String) : Nil
      document = JSON.parse(body)
      document["resourceSpans"]?.try(&.as_a?).try do |resources|
        resources.each { |resource| ingest_resource(resource) }
      end
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
    rescue JSON::ParseException | TypeCastError | KeyError
      answer(context.response, 400, %({"error":"malformed OTLP JSON"}))
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
      bytes = Bytes.new(MAX_BODY + 1)
      size = io.read_greedy(bytes)
      size > MAX_BODY ? nil : String.new(bytes[0, size])
    end

    # Reads past a refused body of up to four times MAX_BODY, so an honest exporter sees
    # the 413 and not a broken pipe.
    private def discard(request : HTTP::Request, length : Int64) : Nil
      return if length > 4 * MAX_BODY

      request.body.try(&.skip(length))
    rescue IO::Error
      nil
    end

    private def ingest_resource(resource : JSON::Any) : Nil
      service = service_of(resource)
      resource["scopeSpans"]?.try(&.as_a?).try do |scopes|
        scopes.each do |scope|
          scope["spans"]?.try(&.as_a?).try do |spans|
            spans.each { |span| store(service, span) }
          end
        end
      end
    end

    private def service_of(resource : JSON::Any) : String
      attributes = resource["resource"]?.try(&.["attributes"]?).try(&.as_a?) || [] of JSON::Any
      found = attributes.find { |item| item["key"]? == "service.name" }
      found.try(&.["value"]?).try(&.["stringValue"]?).try(&.as_s?) || "unknown"
    end

    private def store(service : String, span : JSON::Any) : Nil
      trace_id = span["traceId"]?.try(&.as_s?) || return
      return unless trace_id.matches?(/\A[0-9a-f]{32}\z/)

      collected = parse(service, span) || return
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

    private def parse(service : String, span : JSON::Any) : Crema::CollectedSpan?
      span_id = span["spanId"]?.try(&.as_s?) || return
      parent = span["parentSpanId"]?.try(&.as_s?).try { |id| id.empty? ? nil : id }
      started = nanoseconds(span["startTimeUnixNano"]?) || return
      finished = nanoseconds(span["endTimeUnixNano"]?) || started
      Crema::CollectedSpan.new(service, span_id, parent, span["name"]?.try(&.as_s?) || "",
        span["kind"]?.try(&.as_i?) || 0, started, finished,
        span["status"]?.try(&.["code"]?).try(&.as_i?) == 2, attributes_of(span))
    end

    # OTLP JSON carries 64-bit integers as strings.
    private def nanoseconds(value : JSON::Any?) : Int64?
      value.try { |any| any.as_s?.try(&.to_i64?) || any.as_i64? }
    end

    private def attributes_of(span : JSON::Any) : Hash(String, String)
      found = {} of String => String
      (span["attributes"]?.try(&.as_a?) || [] of JSON::Any).each do |item|
        break if found.size >= MAX_ATTRIBUTES

        key = item["key"]?.try(&.as_s?) || next
        value = scalar(item["value"]?) || next
        found[key] = value.byte_slice(0, MAX_VALUE).scrub
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
