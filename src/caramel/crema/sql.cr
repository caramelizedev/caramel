require "db"
require "../../sugar_orm"
require "../crema"
require "./summary"

module Caramel::Crema
  # Times and tags the statements SugarORM runs for the current trace.
  module Sql
    MAX_SOURCES = 200
    MAX_BINDS   =  20
    MAX_BIND    = 200

    # Runs the block with *tagged*, the statement with the trace's leading
    # comment, and notes the statement on *trace*.
    def self.observe(trace : Trace,
                     sql : String,
                     args : Array(SugarORM::Value),
                     & : String -> R) : R forall R
      tagged = trace.sql_comment.try { |tag| tag + sql } || sql
      summary = Crema.summary(sql)
      started = Time.instant
      begin
        Crema.measure(SpanKind::Sql, summary, sql) do |span|
          annotate(trace, span, args)
          result = yield tagged
          span.try(&.rows = result.rows_affected) if result.is_a?(::DB::ExecResult)
          result
        end
      ensure
        note(trace, sql, summary, Time.instant - started)
      end
    end

    # Counts a slow statement, and a statement repeated within one trace.
    private def self.note(trace : Trace,
                          sql : String,
                          summary : String,
                          elapsed : Time::Span) : Nil
      if elapsed >= Crema.slow_query
        trace.slow_queries += 1
        warn_slow(trace, summary, elapsed)
      end
      return unless trace.recording?

      counts = trace.statement_counts ||= {} of String => Int32
      count = counts[sql] = (counts[sql]? || 0) + 1
      repeat(trace, sql, summary, count) if count >= Trace::REPEATED_QUERY
    end

    private def self.repeat(trace : Trace, sql : String, summary : String, count : Int32) : Nil
      repeats = trace.repeats ||= [] of RepeatEvent
      if known = repeats.find { |entry| entry.sql == sql }
        known.count = count
        return
      end
      source = trace.spans.reverse_each.find { |span| span.detail == sql }.try(&.source)
      repeats << RepeatEvent.new(sql, count, source)
      warn_repeated(summary, count, source)
    end

    {% if flag?(:caramel_development) %}
      # Binds and the calling line, kept on the span in development only.
      private def self.annotate(trace : Trace, span : Span?, args : Array(SugarORM::Value)) : Nil
        return unless span && Crema.development?

        span.binds = args.first(MAX_BINDS).map { |arg| arg.to_s.byte_slice(0, MAX_BIND).scrub }
        return if trace.spans.count(&.kind.sql?) > MAX_SOURCES

        root = Frames.root
        frame = Frames.first_application(caller, root) || return
        location = "#{Frames.relative(frame.path, root)}:#{frame.line}"
        location += ":#{frame.column}" if frame.column
        span.source = location
      end

      private def self.warn_slow(trace : Trace, summary : String, elapsed : Time::Span) : Nil
        return unless Crema.development?

        at = trace.spans.last?.try(&.source).try { |source| " at #{source}" }
        LOG.warn { "slow query #{Trace.ms(elapsed)}ms #{summary}#{at}" }
      end

      private def self.warn_repeated(summary : String, count : Int32, source : String?) : Nil
        return unless Crema.development?

        LOG.warn { "repeated query ×#{count} #{summary}#{source.try { |at| " at #{at}" }}" }
      end
    {% else %}
      private def self.annotate(trace : Trace, span : Span?, args : Array(SugarORM::Value)) : Nil
      end

      private def self.warn_slow(trace : Trace, summary : String, elapsed : Time::Span) : Nil
      end

      private def self.warn_repeated(summary : String, count : Int32, source : String?) : Nil
      end
    {% end %}
  end
end

module SugarORM::Repo
  private def self.observe(sql : String, args : Array(Value), & : String -> R) : R forall R
    trace = Caramel::Crema.current? || return yield(sql)
    Caramel::Crema::Sql.observe(trace, sql, args) { |tagged| yield tagged }
  end

  private def self.observe_checkout(& : -> ::DB::Connection) : ::DB::Connection
    trace = Caramel::Crema.current? || return yield
    started = Time.instant
    begin
      yield
    ensure
      trace.db_wait += Time.instant - started
    end
  end
end
