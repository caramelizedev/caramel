require "json"
require "log"
require "log/json"
require "./sinks"

module Caramel::Crema
  alias Fields = Hash(String, ::Log::Metadata::Value)

  # :nodoc:
  # The fields of a log entry: its context, then its data.
  def self.entry_fields(entry : ::Log::Entry) : Fields
    fields = Fields.new
    entry.context.each { |(key, value)| fields[key.to_s] = value }
    entry.data.each { |(key, value)| fields[key.to_s] = value }
    fields
  end

  # One JSON object per line: `ts`, `level`, `source`, `msg`, then the
  # entry's context and data, flattened. A data key that is one of those four
  # (an error's `source`) is written as `data_source`.
  module JsonFormat
    RESERVED = {"ts", "level", "source", "msg"}

    def self.line(entry : ::Log::Entry) : String
      fields = Crema.entry_fields(entry)
      JSON.build do |json|
        json.object do
          json.field "ts", entry.timestamp.to_utc.to_rfc3339(fraction_digits: 3)
          json.field "level", entry.severity.to_s.downcase
          json.field "source", entry.source
          json.field "msg", entry.message
          fields.each { |key, value| json.field(field_name(key), value) }
          entry.exception.try { |error| json.field "error_type", error.class.to_s }
        end
      end
    end

    private def self.field_name(key : String) : String
      RESERVED.includes?(key) ? "data_#{key}" : key
    end
  end

  # `HH:MM:SS.mmm LEVEL  message`, with the canonical lines in the shape the
  # templates in ADR 0027 give.
  module TextFormat
    CANONICAL = {"request", "job", "schedule", "error"}

    def self.line(entry : ::Log::Entry) : String
      time = entry.timestamp.to_local.to_s("%H:%M:%S.%L")
      "#{time} #{entry.severity.label.ljust(6)} #{body(entry)}"
    end

    private def self.body(entry : ::Log::Entry) : String
      fields = Crema.entry_fields(entry)
      if entry.source == "crema" && CANONICAL.includes?(entry.message)
        return canonical(entry.message, fields)
      end

      parts = [] of String
      parts << (entry.source.empty? ? entry.message : "#{entry.source}: #{entry.message}")
      fields.each { |key, value| parts << "#{key}=#{quote(value.raw.to_s)}" }
      entry.exception.try { |error| parts << "error_type=#{error.class}" }
      parts.join(' ')
    end

    private def self.canonical(message : String, fields : Fields) : String
      parts = case message
              when "request"  then request_parts(fields)
              when "job"      then job_parts(fields)
              when "schedule" then schedule_parts(fields)
              else                 error_parts(fields)
              end
      parts.join(' ')
    end

    private def self.request_parts(fields) : Array(String)
      parts = ["request", text(fields, "method") || "-"]
      parts << (text(fields, "path") || text(fields, "route") || "-")
      parts << (text(fields, "status") || "-")
      parts << "#{ms(fields, "duration_ms")}ms"
      parts << database(fields)
      parts << "view=#{ms(fields, "view_ms")}ms"
      text(fields, "action").try { |action| parts << action }
      pair(parts, fields, "request_id")
      suffixes(parts, fields)
    end

    private def self.job_parts(fields) : Array(String)
      parts = ["job", text(fields, "name") || "-"]
      text(fields, "job_id").try { |id| parts << "##{id}" }
      parts << (text(fields, "outcome") || "-")
      parts << "#{ms(fields, "duration_ms")}ms"
      parts << database(fields)
      pair(parts, fields, "queue")
      pair(parts, fields, "attempt")
      text(fields, "queue_lag_ms").try { parts << "lag=#{ms(fields, "queue_lag_ms")}ms" }
      pair(parts, fields, "request_id")
      suffixes(parts, fields)
    end

    private def self.schedule_parts(fields) : Array(String)
      parts = ["schedule", text(fields, "name") || "-", text(fields, "outcome") || "-"]
      parts << "#{ms(fields, "duration_ms")}ms"
      parts << database(fields)
      suffixes(parts, fields)
    end

    private def self.error_parts(fields) : Array(String)
      parts = ["error", text(fields, "error_class") || "-"]
      pair(parts, fields, "fingerprint")
      text(fields, "location").try { |location| parts << "at #{location}" }
      pair(parts, fields, "source")
      pair(parts, fields, "request_id")
      pair(parts, fields, "message")
      parts
    end

    private def self.suffixes(parts : Array(String), fields) : Array(String)
      repeated = count(fields, "repeated_queries")
      parts << "repeated=#{repeated}" if repeated > 0
      slow = count(fields, "slow_queries")
      parts << "slow_queries=#{slow}" if slow > 0
      text(fields, "error_class").try { |error_class| parts << "error=#{error_class}" }
      parts << "debug" if fields["debug"]?.try(&.raw) == true
      parts
    end

    private def self.database(fields) : String
      "db=#{text(fields, "db_count") || 0}/#{ms(fields, "db_ms")}ms"
    end

    private def self.pair(parts : Array(String), fields, key : String) : Nil
      text(fields, key).try { |value| parts << "#{key}=#{quote(value)}" }
    end

    private def self.text(fields, key : String) : String?
      fields[key]?.try(&.raw.to_s)
    end

    private def self.count(fields, key : String) : Int32
      fields[key]?.try(&.raw.as?(Int32)) || 0
    end

    private def self.ms(fields, key : String) : String
      "%.1f" % (fields[key]?.try(&.raw.as?(Float64)) || 0.0)
    end

    # Values with a space or a quote are written in quotes.
    def self.quote(value : String) : String
      return value unless value.includes?(' ') || value.includes?('"')

      "\"#{value.gsub('"', "\\\"")}\""
    end
  end

  # Writes each entry to *io* in the chosen format, adds it to the current
  # trace as a log span, and offers it to `/v1/tail` subscribers.
  class LogBackend < ::Log::Backend
    MAX_SPAN_TEXT = 1000

    def initialize(@io : IO, @json : Bool)
      super(:sync)
      @lock = Mutex.new
    end

    def write(entry : ::Log::Entry) : Nil
      line = @json ? JsonFormat.line(entry) : TextFormat.line(entry)
      @lock.synchronize do
        @io.puts(line)
        @io.flush
      end
      return if entry.source == "crema"

      add_span(entry)
      Crema.tail.log(entry)
    end

    private def add_span(entry : ::Log::Entry) : Nil
      trace = Crema.current? || return
      text = "#{entry.source}: #{entry.message}".byte_slice(0, MAX_SPAN_TEXT).scrub
      span = trace.open_span(SpanKind::Log, text, nil, Time.instant) || return
      span.level = entry.severity.to_s.downcase
    end
  end

  module Logging
    # `json` or `text`: `CARAMEL_LOG_FORMAT` wins; otherwise text while
    # developing or testing, JSON everywhere else.
    def self.json?(env = ENV) : Bool
      case env["CARAMEL_LOG_FORMAT"]?
      when "json" then true
      when "text" then false
      else             !{"development", "test"}.includes?(env["CARAMEL_ENV"]?)
      end
    end

    def self.level(env = ENV) : ::Log::Severity
      env["LOG_LEVEL"]?.presence.try { |name| ::Log::Severity.parse(name) } || ::Log::Severity::Info
    end

    # Binds every log source to one backend writing to *io*.
    def self.setup(env = ENV, io : IO = STDOUT) : Nil
      ::Log.setup("*", level(env), LogBackend.new(io, json?(env)))
    end
  end
end
