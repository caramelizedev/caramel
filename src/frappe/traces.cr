require "./event_store"
require "./mrdp"
require "../caramel/crema/render"
require "../caramel/crema/summary"

module Caramel::Frappe
  # `frappe traces`, `frappe trace` and `frappe errors`: what the development
  # application did, read from the event log `frappe dev` keeps, without a
  # session or the application's binary.
  class Traces
    DEFAULT_LIMIT = 20
    PRELOAD_FIX   = "preload the association in the query that loads the records, " \
                    "e.g. .preload(:%s)"

    def initialize(@store : EventStore, @root : String, @output : IO)
    end

    # One line per trace, newest first. Agents get the canonical line; people
    # also get the local time.
    def list(agent : Bool,
             errors : Bool = false,
             slow : Float64? = nil,
             limit : Int32 = DEFAULT_LIMIT) : Int32
      found = @store.traces(0, EventStore::MAX_TRACES).map(&.[1])
      found = found.select { |event| event.outcome == "error" } if errors
      found = found.select { |event| event.duration_ms >= slow } if slow
      shown = found.first(limit)
      shown.each { |event| @output.puts(line(event, agent)) }
      @output.puts("OK traces #{shown.size}") if agent
      0
    end

    private def line(event : Crema::TraceEvent, agent : Bool) : String
      text = Crema::Render.line(event)
      return text if agent

      stamp = Time.parse_rfc3339(event.started_at).to_local.to_s("%H:%M:%S")
      "#{stamp} #{text}"
    end

    # One trace in full, as text or Markdown; false when *ref* matches none.
    def show(ref : String, markdown : Bool) : Bool
      event = @store.find(ref) || return false
      @output.puts(markdown ? Crema::Render.markdown(event, @root) : Crema::Render.detail(event))
      true
    end

    # Runtime errors and repeated queries, grouped. Agents get MRDP and exit 1 when
    # anything prints; people get a list.
    def errors(agent : Bool) : Int32
      groups = @store.error_groups
      repeats = repeated_queries
      if groups.empty? && repeats.empty?
        agent ? @output.puts("OK errors 0") : @output.puts("No errors or repeated queries yet.")
        return 0
      end
      groups.each { |group| agent ? runtime_mrdp(group) : runtime_text(group) }
      repeats.each { |repeat| agent ? repeated_mrdp(repeat) : repeated_text(repeat) }
      agent ? 1 : 0
    end

    record Repeat, trace : Crema::TraceEvent, entry : Crema::RepeatEvent

    # The most-repeated statement of each route, worst first.
    private def repeated_queries : Array(Repeat)
      all = @store.traces(0, EventStore::MAX_TRACES).flat_map do |_, trace|
        trace.repeated.map { |entry| Repeat.new(trace, entry) }
      end
      worst = all.group_by { |repeat| {repeat.trace.name, repeat.entry.sql} }
        .values.map(&.max_by(&.entry.count))
      worst.sort_by { |repeat| -repeat.entry.count }
    end

    private def runtime_mrdp(group : EventStore::ErrorGroup) : Nil
      error = group.error
      trace = group.trace
      code = trace && trace.kind == "request" ? "RUNTIME:#{trace.status || 500}" : "RUNTIME"
      subject = trace.try(&.name) || error.source || error.error_class
      MRDP.write(@output, code, "#{error.location || "-"} | #{subject}", [
        {"MSG", "#{error.error_class}: #{error.message} (#{times(group)})"},
        {"FIX", "frappe trace #{error.fingerprint} --md shows the request, " \
                "its queries and the backtrace"},
      ])
    end

    private def times(group : EventStore::ErrorGroup) : String
      "#{group.count} #{group.count == 1 ? "time" : "times"}, last #{group.error.at[11, 8]}"
    end

    private def runtime_text(group : EventStore::ErrorGroup) : Nil
      error = group.error
      where = error.location.try { |location| " at #{location}" }
      @output.puts("#{error.error_class}#{where} (#{times(group)})")
      error.message.try { |message| @output.puts("  #{message}") }
      @output.puts("  frappe trace #{error.fingerprint} --md")
    end

    private def repeated_mrdp(repeat : Repeat) : Nil
      at = "#{repeat.entry.source || "-"} | #{repeat.trace.name}"
      MRDP.write(@output, "REPEATED_QUERY", at, [
        {"MSG", repeat_message(repeat)},
        {"FIX", preload_fix(repeat)},
      ])
    end

    private def repeated_text(repeat : Repeat) : Nil
      @output.puts("#{repeat_message(repeat)} (#{repeat.trace.name})")
      repeat.entry.source.try { |source| @output.puts("  at #{source}") }
      @output.puts("  #{preload_fix(repeat)}")
    end

    private def repeat_message(repeat : Repeat) : String
      "#{Crema.summary(repeat.entry.sql)} ran #{repeat.entry.count} times in one request"
    end

    private def preload_fix(repeat : Repeat) : String
      table = Crema.summary(repeat.entry.sql).partition(' ')[2]
      PRELOAD_FIX % singular(table)
    end

    private def singular(table : String) : String
      return table.sub(/ies\z/, "y") if table.ends_with?("ies")

      table.ends_with?("s") ? table.rchop : table
    end
  end
end
