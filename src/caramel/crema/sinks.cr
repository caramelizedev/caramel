require "log"
require "./error_report"
require "./tally"
require "./trace"

module Caramel::Crema
  LOG = ::Log.for("crema")

  # Receives every finished trace and every error report. Both callbacks run
  # on the reporting fiber and must not block.
  abstract class Sink
    abstract def name : String

    # Asked once when a trace starts: does this sink want its spans?
    def records?(trace : Trace) : Bool
      false
    end

    def finished(trace : Trace) : Nil
    end

    def reported(report : ErrorReport) : Nil
    end
  end

  # The canonical log lines: one entry per finished trace, one per error.
  class LogSink < Sink
    alias Data = Hash(Symbol, ::Log::Metadata::Value)

    def name : String
      "log"
    end

    def finished(trace : Trace) : Nil
      LOG.info(&.emit(trace.kind.wire, trace_data(trace)))
    end

    def reported(report : ErrorReport) : Nil
      data = error_data(report)
      if report.handled?
        LOG.warn(&.emit("error", data))
      else
        LOG.error(&.emit("error", data))
      end
    end

    private def trace_data(trace : Trace) : Data
      data = Data.new
      put(data, :name, trace.name)
      put(data, :request_id, trace.request_id)
      put(data, :trace_id, trace.trace_id)
      put(data, :parent_id, trace.parent_id)
      put(data, :duration_ms, Trace.ms(trace.duration))
      put(data, :outcome, trace.outcome)
      kind_data(data, trace)
      counter_data(data, trace)
      put(data, :debug, true) if trace.debug?
      trace.error.try do |error|
        put(data, :error_class, error.error_class)
        put(data, :fingerprint, error.fingerprint)
      end
      data
    end

    private def kind_data(data : Data, trace : Trace) : Nil
      if trace.kind.request?
        put(data, :method, trace.method)
        put(data, :route, trace.route)
        put(data, :action, trace.action)
        put(data, :status, trace.status)
        put(data, :bytes, trace.bytes)
        put(data, :streamed, trace.streamed?)
        put(data, :path, trace.path) if Crema.development?
      else
        put(data, :job_id, trace.job_id)
        put(data, :queue, trace.queue)
        put(data, :attempt, trace.attempt)
        put(data, :queue_lag_ms, trace.queue_lag.try { |lag| Trace.ms(lag) })
      end
    end

    private def counter_data(data : Data, trace : Trace) : Nil
      put(data, :db_count, trace.db_count)
      put(data, :db_ms, Trace.ms(trace.db_time))
      put(data, :db_wait_ms, Trace.ms(trace.db_wait))
      put(data, :view_ms, Trace.ms(trace.view_time))
      put(data, :outbound_count, trace.outbound_count)
      put(data, :outbound_ms, Trace.ms(trace.outbound_time))
      put(data, :cache_hits, trace.cache_hits)
      put(data, :cache_misses, trace.cache_misses)
      put(data, :enqueued, trace.enqueued)
      put(data, :slow_queries, trace.slow_queries)
      put(data, :repeated_queries, trace.repeats.try(&.size) || 0)
    end

    private def error_data(report : ErrorReport) : Data
      data = Data.new
      put(data, :error_class, report.error_class)
      put(data, :fingerprint, report.fingerprint)
      put(data, :location, report.location)
      put(data, :source, report.source)
      put(data, :handled, report.handled?)
      put(data, :request_id, report.request_id)
      put(data, :trace_id, report.trace_id)
      put(data, :message, report.message) if Crema.development?
      data
    end

    private def put(data : Data, key : Symbol, value) : Nil
      data[key] = ::Log::Metadata::Value.new(value) unless value.nil?
    end
  end

  # Aggregates since the process started: what `/v1/metrics` and the
  # console's overview read.
  class MetricSink < Sink
    # Distinct series kept; a client that invents labels folds into `(other)`.
    MAX_KEYS = 1000

    getter durations : Tally = Tally.new(MAX_KEYS)

    def initialize
      @lock = Mutex.new
      @requests = {} of {String, String, Int32} => Int64
      @outcomes = {} of {String, String, String} => Int64
      @lag = {} of String => Histogram
      @lag_ms = {} of String => Float64
      @errors = {} of String => Int64
    end

    def name : String
      "metrics"
    end

    def finished(trace : Trace) : Nil
      outcome = trace.outcome
      @durations.record(trace.kind.wire, trace.name, Trace.ms(trace.duration), outcome == "error")
      @lock.synchronize do
        if trace.kind.request?
          count_request(trace)
        else
          count_run(trace, outcome)
        end
      end
    end

    def reported(report : ErrorReport) : Nil
      @lock.synchronize do
        @errors[report.error_class] = (@errors[report.error_class]? || 0_i64) + 1
      end
    end

    # Requests by `{method, route, status}`; an unmatched route is `(none)`.
    def requests : Hash({String, String, Int32}, Int64)
      @lock.synchronize { @requests.dup }
    end

    # Jobs and schedules by `{kind, name, outcome}`.
    def outcomes : Hash({String, String, String}, Int64)
      @lock.synchronize { @outcomes.dup }
    end

    # How long jobs waited past their `run_at`, per queue: the histogram and the sum in ms.
    def lag : Hash(String, {Histogram, Float64})
      @lock.synchronize do
        @lag.to_h { |queue, histogram| {queue, {Histogram.new(histogram.to_a), @lag_ms[queue]}} }
      end
    end

    def errors : Hash(String, Int64)
      @lock.synchronize { @errors.dup }
    end

    # Requests since start: how many, how many failed and the 95th percentile in ms.
    def request_summary : {Int64, Int64, Float64}
      merged = Histogram.new
      total = errors = 0_i64
      slowest = 0.0
      @durations.snapshot.each do |kind, _, entry|
        next unless kind == "request"

        merged.add(entry.histogram)
        total += entry.count
        errors += entry.errors
        slowest = {slowest, entry.max_ms}.max
      end
      {total, errors, merged.quantile(0.95, slowest)}
    end

    private def count_request(trace : Trace) : Nil
      key = {trace.method || "", trace.route || "(none)", trace.status || 0}
      key = {key[0], "(other)", key[2]} if @requests.size >= MAX_KEYS && !@requests.has_key?(key)
      @requests[key] = (@requests[key]? || 0_i64) + 1
    end

    private def count_run(trace : Trace, outcome : String) : Nil
      key = {trace.kind.wire, trace.name, outcome}
      @outcomes[key] = (@outcomes[key]? || 0_i64) + 1
      queue = trace.queue
      lag = trace.queue_lag
      return unless queue && lag

      ms = Trace.ms(lag)
      (@lag[queue] ||= Histogram.new).observe(ms)
      @lag_ms[queue] = (@lag_ms[queue]? || 0.0) + ms
    end
  end

  # What `/v1/tail` streams. Serializes an event only while a subscriber
  # exists; a subscriber whose channel is full loses the event.
  class TailSink < Sink
    CAPACITY = 1000

    record Filter, errors : Bool = false, slow_ms : Float64? = nil, logs : Bool = false

    class Subscriber
      getter channel : Channel(String) = Channel(String).new(CAPACITY)
      getter filter : Filter

      def initialize(@filter : Filter)
      end
    end

    def initialize
      @lock = Mutex.new
      @subscribers = [] of Subscriber
    end

    def name : String
      "tail"
    end

    def subscribe(filter : Filter) : Subscriber
      subscriber = Subscriber.new(filter)
      @lock.synchronize { @subscribers = @subscribers + [subscriber] }
      subscriber
    end

    def unsubscribe(subscriber : Subscriber) : Nil
      @lock.synchronize { @subscribers = @subscribers.reject(&.same?(subscriber)) }
    end

    def subscribed? : Bool
      !@subscribers.empty?
    end

    def finished(trace : Trace) : Nil
      subscribers = @subscribers
      return if subscribers.empty?

      line = nil
      subscribers.each do |subscriber|
        next unless wants?(subscriber.filter, trace)
        line ||= trace.to_event(Detail::Production).to_json
        offer(subscriber, line)
      end
    end

    def reported(report : ErrorReport) : Nil
      subscribers = @subscribers
      return if subscribers.empty?

      line = nil
      subscribers.each do |subscriber|
        filter = subscriber.filter
        next unless filter.slow_ms.nil? || filter.errors
        line ||= report.to_event(Detail::Production).to_json
        offer(subscriber, line)
      end
    end

    # Offers a log entry to subscribers that asked for logs.
    def log(entry : ::Log::Entry) : Nil
      subscribers = @subscribers
      return if subscribers.empty?

      line = nil
      subscribers.each do |subscriber|
        next unless subscriber.filter.logs
        line ||= log_line(entry)
        offer(subscriber, line)
      end
    end

    def wants_logs? : Bool
      @subscribers.any?(&.filter.logs)
    end

    private def wants?(filter : Filter, trace : Trace) : Bool
      return true if trace.debug?
      return false if filter.errors && trace.outcome != "error"

      slow = filter.slow_ms
      slow.nil? || Trace.ms(trace.duration) >= slow
    end

    private def offer(subscriber : Subscriber, line : String) : Nil
      select
      when subscriber.channel.send(line)
      else
        Crema.drop("tail")
      end
    end

    private def log_line(entry : ::Log::Entry) : String
      JSON.build do |json|
        json.object do
          json.field "v", WIRE_VERSION
          json.field "type", "log"
          json.field "at", entry.timestamp.to_utc.to_rfc3339(fraction_digits: 3)
          json.field "level", entry.severity.to_s.downcase
          json.field "source", entry.source
          json.field "message", entry.message
        end
      end
    end
  end

  # Runs a block `Crema.on_error` registered for each error report.
  class BlockSink < Sink
    def initialize(@block : ErrorReport ->)
    end

    def name : String
      "on_error"
    end

    def reported(report : ErrorReport) : Nil
      @block.call(report)
    end
  end
end
