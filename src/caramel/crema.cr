require "http"
require "uri"
require "./response"
require "./crema/ids"
require "./crema/redact"
require "./crema/frames"
require "./crema/event"
require "./crema/trace"
require "./crema/error_report"
require "./crema/tally"
require "./crema/sinks"
require "./crema/logging"

module Caramel
  # Observability: every request, job and schedule run is a trace with a
  # stable id, one wide log line and, when a sink wants them, timed spans.
  # Crema reports to sinks and never raises into the work it observes.
  #
  # ```
  # Caramel::Crema.on_error { |report| Tracker.capture(report.error_class) }
  # Caramel::Crema.slow_request = 500.milliseconds
  # ```
  module Crema
    # A finished request at least this slow is flagged `slow`.
    class_property slow_request : Time::Span = 1.second
    # A finished job or schedule run at least this slow is flagged `slow`.
    class_property slow_job : Time::Span = 5.seconds
    # An SQL statement at least this slow counts in `slow_queries`.
    class_property slow_query : Time::Span = 100.milliseconds

    @@lock = Mutex.new
    @@metrics = MetricSink.new
    @@tail = TailSink.new
    @@sinks : Array(Sink) = [LogSink.new, @@metrics, @@tail] of Sink
    @@active = Set(Trace).new
    @@dropped = {} of String => Int64
    @@secrets : Array(String)?

    def self.metrics : MetricSink
      @@metrics
    end

    def self.tail : TailSink
      @@tail
    end

    def self.sinks : Array(Sink)
      @@sinks
    end

    # True when `CARAMEL_ENV=development`: the only mode whose log lines and
    # pages may name request paths and exception messages.
    def self.development? : Bool
      ENV["CARAMEL_ENV"]? == "development"
    end

    # The secret-looking environment values, read once per process.
    def self.secrets : Array(String)
      @@secrets ||= Redact.secrets
    end

    # The trace the running fiber works for.
    def self.current? : Trace?
      Fiber.current.__crema_trace
    end

    # Every trace in flight.
    def self.in_flight : Array(Trace)
      @@lock.synchronize { @@active.to_a }
    end

    def self.subscribe(sink : Sink) : Sink
      @@lock.synchronize { @@sinks = @@sinks + [sink] }
      sink
    end

    def self.unsubscribe(sink : Sink) : Nil
      @@lock.synchronize { @@sinks = @@sinks.reject(&.same?(sink)) }
    end

    # Counts *count* events a sink named *sink* lost.
    def self.drop(sink : String, count : Int64 = 1_i64) : Nil
      @@lock.synchronize { @@dropped[sink] = (@@dropped[sink]? || 0_i64) + count }
    end

    def self.dropped : Hash(String, Int64)
      @@lock.synchronize { @@dropped.dup }
    end

    # Calls *block* with each error report, handled or not. The report holds
    # a redacted message and backtrace; send it to your error tracker.
    def self.on_error(&block : ErrorReport ->) : Nil
      subscribe(BlockSink.new(block))
    end

    # Traces *request*: binds a trace to the fiber, runs the block, adds the
    # response headers and tells every sink. An exception that escapes the
    # block is reported once and raised again.
    def self.request(request : HTTP::Request, & : Trace -> Response) : Response
      trace = request_trace(request)
      response = begin
        bound(trace) { guarded(trace) { yield trace } }
      rescue error
        trace.status = 500
        finish(trace)
        raise error
      end
      complete(trace, response)
      response
    end

    # Names the current trace after the route it matched.
    def self.routed(method : String, route : String, action : String) : Nil
      trace = current? || return
      trace.method = method
      trace.route = route
      trace.action = action
      trace.name = "#{method} #{route}"
      trace.sql_comment = sql_tag("action", action)
    end

    # Reports *error* to every sink and returns the report. It never raises.
    def self.report(error : Exception,
                    *,
                    handled : Bool = true,
                    source : String? = nil,
                    request_id : String? = nil) : ErrorReport
      trace = current?
      report = ErrorReport.build(error, handled, source || trace.try(&.name),
        trace.try(&.request_id) || request_id, trace.try(&.trace_id))
      if trace
        trace.error ||= report
        trace.reported = error
      end
      each_sink(&.reported(report))
      report
    end

    # Times the block as a *kind* step of the current trace. With no trace it
    # only yields nil. A recording trace yields the span to annotate.
    def self.measure(kind : SpanKind,
                     name : String,
                     detail : String? = nil,
                     & : Span? -> T) : T forall T
      trace = current?
      return yield(nil) unless trace

      started = Time.instant
      span = trace.open_span(kind, name, detail, started)
      begin
        yield span
      rescue error
        span.try(&.error_class = error.class.to_s)
        raise error
      ensure
        elapsed = Time.instant - started
        span.try(&.duration = elapsed)
        trace.count(kind, elapsed)
      end
    end

    # `/*key='value'*/ ` for the start of a statement, so PostgreSQL's logs
    # and `pg_stat_activity` name the code that ran it.
    def self.sql_tag(key : String, value : String) : String
      encoded = URI.encode_path_segment(value).gsub("*/", "*%2F").gsub("'", "\\\\'")
      "/*#{key}='#{encoded}'*/ "
    end

    private def self.request_trace(request : HTTP::Request) : Trace
      trace_id, span_id = Ids.generate
      parent = Ids.parse_traceparent(request.headers["traceparent"]?)
      trace_id = parent[0] if parent
      trace = Trace.new(Kind::Request, "#{request.method} (none)", trace_id, span_id)
      trace.parent_id = parent.try(&.[1])
      trace.parent_sampled = parent.try(&.[2])
      trace.request_id = Ids.request_id(request.headers["X-Request-ID"]?)
      trace.method = request.method
      trace.path = request.path
      start(trace)
    end

    # Decides once whether *trace* records spans.
    def self.start(trace : Trace) : Trace
      sinks = @@sinks
      sinks.each { |sink| trace.recording = true if sink_records?(sink, trace) }
      trace
    end

    private def self.sink_records?(sink : Sink, trace : Trace) : Bool
      sink.records?(trace)
    rescue error
      sink_failed(sink, error)
      false
    end

    # Binds *trace* to the running fiber and its log context for the block.
    def self.bound(trace : Trace, & : -> T) : T forall T
      fiber = Fiber.current
      previous = fiber.__crema_trace
      fiber.__crema_trace = trace
      @@lock.synchronize { @@active << trace }
      begin
        ::Log.with_context(log_context(trace)) { yield }
      ensure
        fiber.__crema_trace = previous
        @@lock.synchronize { @@active.delete(trace) }
      end
    end

    private def self.guarded(trace : Trace, & : -> T) : T forall T
      yield
    rescue error
      report(error, handled: false) unless trace.reported.same?(error)
      raise error
    end

    private def self.log_context(trace : Trace) : Hash(Symbol, String)
      context = {:trace_id => trace.trace_id}
      trace.request_id.try { |id| context[:request_id] = id }
      context
    end

    private def self.complete(trace : Trace, response : Response) : Nil
      response.headers["X-Request-ID"] = trace.request_id || ""
      response.headers["X-Caramel-Trace"] = trace.trace_id if trace.debug?
      trace.status = response.status
      trace.streamed = !response.streamer.nil?
      trace.bytes = response.body.bytesize.to_i64 unless trace.streamed?
      finish(trace)
    end

    # Fixes the duration, flags a slow trace and tells every sink.
    def self.finish(trace : Trace) : Nil
      duration = trace.finish
      limit = trace.kind.request? ? slow_request : slow_job
      trace.slow = duration >= limit
      each_sink(&.finished(trace))
    end

    private def self.each_sink(& : Sink ->) : Nil
      @@sinks.each do |sink|
        yield sink
      rescue error
        sink_failed(sink, error)
      end
    end

    private def self.sink_failed(sink : Sink, error : Exception) : Nil
      LOG.warn { "sink=#{sink.name} failed error_type=#{error.class}" }
    end
  end
end
