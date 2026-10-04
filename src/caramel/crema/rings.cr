require "./sinks"

module Caramel::Crema
  # The newest error of each fingerprint since this process started, with its
  # redacted message and backtrace. It lives in memory and is lost on restart;
  # only the owner-only ops socket serves it.
  class ErrorRing < Sink
    MAX_FINGERPRINTS = 500

    class Entry
      getter fingerprint : String
      getter first_seen : Time
      property last_seen : Time
      property count : Int64 = 1_i64
      property report : ErrorReport

      def initialize(@report : ErrorReport)
        @fingerprint = @report.fingerprint
        @first_seen = @last_seen = @report.occurred_at
      end
    end

    def initialize
      @lock = Mutex.new
      @entries = {} of String => Entry
    end

    def name : String
      "errors"
    end

    def reported(report : ErrorReport) : Nil
      @lock.synchronize do
        if entry = @entries[report.fingerprint]?
          entry.count += 1
          entry.last_seen = report.occurred_at
          entry.report = report
        else
          evict if @entries.size >= MAX_FINGERPRINTS
          @entries[report.fingerprint] = Entry.new(report)
        end
      end
    end

    # Every entry, most recently seen first.
    def entries : Array(Entry)
      @lock.synchronize { @entries.values.sort_by!(&.last_seen).reverse! }
    end

    def find(fingerprint : String) : Entry?
      @lock.synchronize { @entries[fingerprint]? }
    end

    private def evict : Nil
      oldest = @entries.min_by(&.[1].last_seen)
      @entries.delete(oldest[0])
    end
  end

  # The newest 200 finished traces that failed, ran slow or belonged to a
  # debug token, each with the spans it recorded. It asks every trace to
  # record, so one that turns out to be worth keeping has its spans.
  class TraceRing < Sink
    CAPACITY = 200

    def initialize
      @lock = Mutex.new
      @traces = [] of TraceEvent
    end

    def name : String
      "traces"
    end

    def records?(trace : Trace) : Bool
      true
    end

    def finished(trace : Trace) : Nil
      reason = reason_for(trace) || return
      event = trace.to_event(Detail::Production)
      event.reason = reason
      @lock.synchronize do
        @traces << event
        @traces.shift if @traces.size > CAPACITY
      end
    end

    # Newest first, optionally only those kept for *reason*.
    def traces(reason : String? = nil, limit : Int32 = 50) : Array(TraceEvent)
      @lock.synchronize do
        kept = reason ? @traces.select { |event| event.reason == reason } : @traces.dup
        kept.reverse!.first(limit)
      end
    end

    # The newest trace whose trace id or request id starts with *ref*.
    def find(ref : String) : TraceEvent?
      return if ref.size < 6

      @lock.synchronize do
        @traces.reverse_each.find do |event|
          event.trace_id.starts_with?(ref) || event.request_id.try(&.starts_with?(ref)) == true
        end
      end
    end

    private def reason_for(trace : Trace) : String?
      return "error" if trace.outcome == "error"
      return "slow" if trace.slow?

      trace.debug? ? "debug" : nil
    end
  end
end
