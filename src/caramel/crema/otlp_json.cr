require "json"
require "random/secure"
require "time"
require "../version"
require "./event"

module Caramel::Crema
  # Traces as OTLP/HTTP JSON, a pure function of the wire-format events. The exporter
  # and Frappé's forwarding to Latte's collector share it, so it needs nothing but the
  # standard library and the event structs. Attributes name the parameterized SQL and
  # the route, never a bind value, a path or a message.
  module OtlpJson
    SERVER   = 2
    CLIENT   = 3
    INTERNAL = 1
    CONSUMER = 5
    ERROR    = 2

    def self.encode(events : Array(TraceEvent), service : String, environment : String) : String
      JSON.build do |json|
        json.object do
          json.field "resourceSpans" do
            json.array do
              json.object do
                json.field "resource" { resource(json, service, environment) }
                json.field "scopeSpans" do
                  json.array { scope(json, events) }
                end
              end
            end
          end
        end
      end
    end

    private def self.resource(json : JSON::Builder, service : String, environment : String) : Nil
      json.object do
        json.field "attributes" do
          json.array do
            string(json, "service.name", service)
            string(json, "telemetry.sdk.name", "caramel.crema")
            string(json, "telemetry.sdk.language", "crystal")
            string(json, "telemetry.sdk.version", Caramel::VERSION)
            string(json, "deployment.environment.name", environment)
          end
        end
      end
    end

    private def self.scope(json : JSON::Builder, events : Array(TraceEvent)) : Nil
      json.object do
        json.field "scope" do
          json.object do
            json.field "name", "caramel.crema"
            json.field "version", Caramel::VERSION
          end
        end
        json.field "spans" do
          json.array { events.each { |event| spans(json, event) } }
        end
      end
    end

    private def self.spans(json : JSON::Builder, event : TraceEvent) : Nil
      started = nanoseconds(Time.parse_rfc3339(event.started_at))
      root(json, event, started)
      event.spans.each do |span|
        child(json, event, span, started) unless span.kind.in?("log", "dump")
      end
    end

    private def self.root(json : JSON::Builder, event : TraceEvent, started : Int64) : Nil
      finished = started + milliseconds(event.duration_ms)
      json.object do
        json.field "traceId", event.trace_id
        json.field "spanId", event.span_id
        event.parent_id.try { |parent| json.field "parentSpanId", parent }
        json.field "name", event.name
        json.field "kind", root_kind(event)
        json.field "startTimeUnixNano", started.to_s
        json.field "endTimeUnixNano", finished.to_s
        json.field "attributes" do
          json.array { root_attributes(json, event) }
        end
        failure(json, event.error.try(&.error_class), finished) if event.outcome == "error"
      end
    end

    private def self.root_kind(event : TraceEvent) : Int32
      case event.kind
      when "request" then SERVER
      when "job"     then CONSUMER
      else                INTERNAL
      end
    end

    private def self.root_attributes(json : JSON::Builder, event : TraceEvent) : Nil
      if event.kind == "job"
        string(json, "messaging.system", "caramel.cold_brew")
        event.queue.try { |queue| string(json, "messaging.destination.name", queue) }
        string(json, "messaging.operation.type", "process")
        event.job_id.try { |id| string(json, "messaging.message.id", id.to_s) }
        event.attempt.try { |attempt| integer(json, "caramel.job.attempt", attempt) }
      elsif event.kind == "request"
        event.method.try { |method| string(json, "http.request.method", method) }
        event.route.try { |route| string(json, "http.route", route) }
        event.status.try { |status| integer(json, "http.response.status_code", status) }
        event.action.try { |action| string(json, "caramel.action", action) }
      end
      event.request_id.try { |id| string(json, "caramel.request_id", id) }
    end

    private def self.child(json : JSON::Builder,
                           event : TraceEvent,
                           span : SpanEvent,
                           started : Int64) : Nil
      start = started + milliseconds(span.offset_ms)
      finished = start + milliseconds(span.duration_ms)
      json.object do
        json.field "traceId", event.trace_id
        json.field "spanId", Random::Secure.hex(8)
        json.field "parentSpanId", event.span_id
        json.field "name", span.name
        json.field "kind", span.kind.in?("sql", "http") ? CLIENT : INTERNAL
        json.field "startTimeUnixNano", start.to_s
        json.field "endTimeUnixNano", finished.to_s
        json.field "attributes" do
          json.array { child_attributes(json, span) }
        end
        failure(json, span.error_class, finished) if span.error_class
      end
    end

    private def self.child_attributes(json : JSON::Builder, span : SpanEvent) : Nil
      case span.kind
      when "sql"
        string(json, "db.system.name", "postgresql")
        operation = (span.detail || span.name).lstrip.partition(' ')[0].upcase
        string(json, "db.operation.name", operation)
        span.detail.try { |sql| string(json, "db.query.text", sql) }
      when "http"
        method, _, host = span.name.partition(' ')
        string(json, "http.request.method", method)
        string(json, "server.address", host)
        span.status.try { |status| integer(json, "http.response.status_code", status) }
      end
    end

    # Status "error", and an `exception` event naming the class when it is known.
    private def self.failure(json : JSON::Builder, error_class : String?, finished : Int64) : Nil
      json.field "status" do
        json.object { json.field "code", ERROR }
      end
      return unless error_class

      json.field "events" do
        json.array do
          json.object do
            json.field "timeUnixNano", finished.to_s
            json.field "name", "exception"
            json.field "attributes" do
              json.array { string(json, "exception.type", error_class) }
            end
          end
        end
      end
    end

    private def self.string(json : JSON::Builder, key : String, value : String) : Nil
      json.object do
        json.field "key", key
        json.field "value" do
          json.object { json.field "stringValue", value }
        end
      end
    end

    private def self.integer(json : JSON::Builder, key : String, value : Int) : Nil
      json.object do
        json.field "key", key
        json.field "value" do
          json.object { json.field "intValue", value.to_s }
        end
      end
    end

    private def self.nanoseconds(time : Time) : Int64
      time.to_unix * 1_000_000_000_i64 + time.nanosecond
    end

    private def self.milliseconds(value : Float64) : Int64
      (value * 1_000_000).round.to_i64
    end
  end
end
