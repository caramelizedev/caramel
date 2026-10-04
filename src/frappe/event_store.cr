require "json"
require "./site_log"
require "../caramel/crema/event"

module Caramel::Frappe
  # The development events one project's application sent, newest last: its
  # recent traces, the errors that happened outside a trace and Frappé's own
  # builds. `DevEvents` fills one live; `frappe traces` and friends replay the
  # event log into one.
  class EventStore
    MAX_TRACES = 500
    MAX_ERRORS = 200
    MAX_BUILDS =  50
    LOG_NAME   = "events.jsonl"

    alias Event = Crema::TraceEvent | Crema::ErrorEvent | Crema::BuildEvent

    # One kind of error: its newest report, the trace that report belongs to
    # (if any) and how often it happened.
    record ErrorGroup,
      error : Crema::ErrorEvent,
      trace : Crema::TraceEvent?,
      count : Int32

    def initialize
      @lock = Mutex.new
      @traces = [] of {Int64, Crema::TraceEvent}
      @errors = [] of Crema::ErrorEvent
      @builds = [] of Crema::BuildEvent
      @seq = 0_i64
    end

    # The event on one log line, or nil for anything else.
    def self.parse(line : String) : Event?
      case JSON.parse(line)["type"]?.try(&.as_s?)
      when "trace" then Crema::TraceEvent.from_json(line)
      when "error" then Crema::ErrorEvent.from_json(line)
      when "build" then Crema::BuildEvent.from_json(line)
      end
    rescue JSON::ParseException | JSON::SerializableError
      nil
    end

    # Stores the event on *line*; nil when the line is not one.
    def ingest(line : String) : Event?
      event = self.class.parse(line) || return
      add(event)
      event
    end

    def add(event : Event) : Nil
      @lock.synchronize do
        case event
        in Crema::TraceEvent
          @seq += 1
          @traces << {@seq, event}
          @traces.shift if @traces.size > MAX_TRACES
        in Crema::ErrorEvent
          @errors << event
          @errors.shift if @errors.size > MAX_ERRORS
        in Crema::BuildEvent
          @builds << event
          @builds.shift if @builds.size > MAX_BUILDS
        end
      end
    end

    # Loads what earlier sessions logged: the rolled file, then the current one.
    def replay(log_directory : String) : Nil
      path = File.join(log_directory, LOG_NAME)
      [path + ".previous", path].each do |file|
        next unless File.file?(file)
        SiteLog.validate_file(file)
        File.each_line(file) { |line| ingest(line) }
      end
    end

    # The sequence number of the newest trace, 0 before any.
    def latest : Int64
      @lock.synchronize { @seq }
    end

    # Traces newer than *after*, newest first.
    def traces(after : Int64 = 0, limit : Int32 = 50) : Array({Int64, Crema::TraceEvent})
      @lock.synchronize do
        @traces.select { |seq, _| seq > after }.reverse!.first(limit)
      end
    end

    # `last`, `last-error`, or a prefix of 6 or more characters of a trace id, a
    # request id or the fingerprint of the error a trace ended with.
    def find(ref : String) : Crema::TraceEvent?
      @lock.synchronize do
        case ref
        when "last"       then @traces.last?.try(&.[1])
        when "last-error" then @traces.reverse_each.find { |_, event| failed?(event) }.try(&.[1])
        else
          return if ref.size < 6

          @traces.reverse_each.find { |_, event| matches?(event, ref) }.try(&.[1])
        end
      end
    end

    def for_request(id : String) : Crema::TraceEvent?
      @lock.synchronize do
        @traces.reverse_each.find { |_, event| event.request_id == id }.try(&.[1])
      end
    end

    # Every error event, from traces and standalone, oldest first.
    def errors : Array(Crema::ErrorEvent)
      @lock.synchronize { error_entries.map(&.[0]) }
    end

    # Error reports grouped by fingerprint, the most recent kind first.
    def error_groups : Array(ErrorGroup)
      entries = @lock.synchronize { error_entries }
      groups = entries.group_by { |error, _| error.fingerprint }
      found = groups.values.map { |group| ErrorGroup.new(group.last[0], group.last[1], group.size) }
      found.sort_by!(&.error.at).reverse!
    end

    def builds : Array(Crema::BuildEvent)
      @lock.synchronize { @builds.dup }
    end

    private def error_entries : Array({Crema::ErrorEvent, Crema::TraceEvent?})
      entries = [] of {Crema::ErrorEvent, Crema::TraceEvent?}
      @traces.each { |_, trace| trace.error.try { |error| entries << {error, trace} } }
      @errors.each { |error| entries << {error, nil} }
      entries.sort_by { |error, _| error.at }
    end

    private def failed?(event : Crema::TraceEvent) : Bool
      event.outcome == "error"
    end

    private def matches?(event : Crema::TraceEvent, ref : String) : Bool
      event.trace_id.starts_with?(ref) ||
        event.request_id.try(&.starts_with?(ref)) == true ||
        event.error.try(&.fingerprint.starts_with?(ref)) == true
    end
  end
end
