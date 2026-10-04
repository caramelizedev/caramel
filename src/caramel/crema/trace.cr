require "./event"

module Caramel::Crema
  enum Kind
    Request
    Job
    Schedule

    def wire : String
      to_s.downcase
    end
  end

  enum SpanKind
    Sql
    Http
    View
    Enqueue
    Log
    Dump

    def wire : String
      to_s.downcase
    end
  end

  # One timed step inside a trace. Spans exist only while a sink records.
  class Span
    getter kind : SpanKind
    getter name : String
    property detail : String?
    getter offset : Time::Span
    property duration : Time::Span = Time::Span.zero
    property rows : Int64?
    property status : Int32?
    property level : String?
    property error_class : String?
    property source : String?
    property binds : Array(String)?

    def initialize(@kind : SpanKind, @name : String, @offset : Time::Span)
    end

    def to_event(detail : Detail) : SpanEvent
      event = SpanEvent.new(@kind.wire, @name, Trace.ms(@offset), Trace.ms(@duration))
      event.detail = @detail
      event.rows = @rows
      event.status = @status
      event.level = @level
      event.error_class = @error_class
      return event unless detail.development?

      event.source = @source
      event.binds = @binds
      event
    end
  end

  # What one request, job or schedule run did. Created by `Crema.request`,
  # `Crema.job` or `Crema.schedule`, bound to the running fiber, and handed
  # to every sink when it finishes.
  class Trace
    MAX_SPANS      = 200
    REPEATED_QUERY =   5

    getter kind : Kind
    getter trace_id : String
    getter span_id : String
    getter started_at : Time
    getter started : Time::Instant
    property name : String
    property parent_id : String?
    property request_id : String?
    property method : String?
    property route : String?
    property action : String?
    property path : String?
    property status : Int32?
    property bytes : Int64?
    property? streamed : Bool = false
    property job_id : Int64?
    property queue : String?
    property attempt : Int32?
    property queue_lag : Time::Span?
    property? debug : Bool = false
    property? slow : Bool = false
    property? recording : Bool = false
    property parent_sampled : Bool?
    property? sampled : Bool = true
    property sql_comment : String?
    property error : ErrorReport?
    property db_count : Int32 = 0
    property db_time : Time::Span = Time::Span.zero
    property db_wait : Time::Span = Time::Span.zero
    property view_time : Time::Span = Time::Span.zero
    property outbound_count : Int32 = 0
    property outbound_time : Time::Span = Time::Span.zero
    property cache_hits : Int32 = 0
    property cache_misses : Int32 = 0
    property enqueued : Int32 = 0
    property slow_queries : Int32 = 0
    property dropped_spans : Int32 = 0
    property view_depth : Int32 = 0
    getter spans : Array(Span) = [] of Span
    property statement_counts : Hash(String, Int32)?
    property repeats : Array(RepeatEvent)?
    @duration : Time::Span?

    def initialize(@kind : Kind, @name : String, @trace_id : String, @span_id : String)
      @started_at = Time.utc
      @started = Time.instant
    end

    def self.ms(span : Time::Span) : Float64
      (span.total_microseconds / 1000.0).round(3)
    end

    def elapsed : Time::Span
      Time.instant - @started
    end

    # Fixes the duration; later calls change nothing.
    def finish : Time::Span
      @duration ||= elapsed
    end

    def duration : Time::Span
      @duration || elapsed
    end

    def outcome : String
      return "error" if @error || (@status || 0) >= 500

      "ok"
    end

    def traceparent : String
      Ids.traceparent(@trace_id, @span_id, @sampled)
    end

    # The job context stored with work this trace enqueues.
    def propagation : String
      JSON.build do |json|
        json.object do
          json.field "traceparent", traceparent
          @request_id.try { |id| json.field "request_id", id }
          json.field "debug", true if @debug
        end
      end
    end

    # Opens a span at *started*, or counts a dropped one past MAX_SPANS.
    def open_span(kind : SpanKind, name : String, detail : String?, started : Time::Instant) : Span?
      return unless @recording
      if @spans.size >= MAX_SPANS
        @dropped_spans += 1
        return
      end
      span = Span.new(kind, name, started - @started)
      span.detail = detail
      @spans << span
      span
    end

    # Adds a finished step of *kind* to the counters it owns.
    def count(kind : SpanKind, elapsed : Time::Span) : Nil
      case kind
      in .sql?     then @db_count += 1; @db_time += elapsed
      in .http?    then @outbound_count += 1; @outbound_time += elapsed
      in .view?    then @view_time += elapsed if @view_depth == 0
      in .enqueue? then @enqueued += 1
      in .log?, .dump?
      end
    end

    def to_event(detail : Detail) : TraceEvent
      event = TraceEvent.new(@kind.wire, @name, @trace_id, @span_id,
        @started_at.to_rfc3339(fraction_digits: 3), Trace.ms(duration), outcome)
      copy_identity(event, detail)
      copy_counters(event)
      event.spans = @spans.map(&.to_event(detail))
      event.repeated = (@repeats || [] of RepeatEvent).map { |repeat| repeat_event(repeat, detail) }
      event.error = @error.try(&.to_event(detail))
      event
    end

    private def copy_identity(event : TraceEvent, detail : Detail) : Nil
      event.parent_id = @parent_id
      event.request_id = @request_id
      event.status = @status
      event.method = @method
      event.route = @route
      event.action = @action
      event.path = @path if detail.development?
      event.job_id = @job_id
      event.queue = @queue
      event.attempt = @attempt
      event.queue_lag_ms = @queue_lag.try { |lag| Trace.ms(lag) }
      event.debug = @debug
      event.streamed = @streamed
      event.slow = @slow
      event.bytes = @bytes
    end

    private def copy_counters(event : TraceEvent) : Nil
      event.db_count = @db_count
      event.db_ms = Trace.ms(@db_time)
      event.db_wait_ms = Trace.ms(@db_wait)
      event.view_ms = Trace.ms(@view_time)
      event.outbound_count = @outbound_count
      event.outbound_ms = Trace.ms(@outbound_time)
      event.cache_hits = @cache_hits
      event.cache_misses = @cache_misses
      event.enqueued = @enqueued
      event.slow_queries = @slow_queries
      event.dropped_spans = @dropped_spans
    end

    private def repeat_event(repeat : RepeatEvent, detail : Detail) : RepeatEvent
      return repeat if detail.development?

      RepeatEvent.new(repeat.sql, repeat.count)
    end
  end
end

class Fiber
  # The trace this fiber is working for; set only by `Crema.request`,
  # `Crema.job` and `Crema.schedule`.
  property __crema_trace : Caramel::Crema::Trace? = nil
  # The exception this fiber last reported, so a rescue further up the stack
  # does not report it twice.
  property __crema_reported : Exception? = nil
end
