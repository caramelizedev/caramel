require "../html"
require "./editor"
require "./event"
require "./frames"
require "./redact"

module Caramel::Crema
  # Pure functions over the wire-format events, shared by `ops tail`,
  # `frappe traces`, the ops console and the development inspector. They
  # take events, not live objects, so Frappé and Latte can use them.
  module Render
    APPLICATION_DIRECTORIES = {"app/", "config/", "src/", "db/"}

    @@secrets : Array(String)? = nil

    # One line, as the canonical log line reads without its time and level.
    def self.line(event : TraceEvent | ErrorEvent) : String
      parts = event.is_a?(TraceEvent) ? trace_parts(event) : error_parts(event)
      parts.join(' ')
    end

    private def self.trace_parts(event : TraceEvent) : Array(String)
      parts = case event.kind
              when "job"      then job_parts(event)
              when "schedule" then schedule_parts(event)
              else                 request_parts(event)
              end
      parts << "repeated=#{event.repeated.size}" unless event.repeated.empty?
      parts << "slow_queries=#{event.slow_queries}" if event.slow_queries > 0
      event.error.try { |error| parts << "error=#{error.error_class}" }
      parts << "debug" if event.debug?
      parts
    end

    private def self.request_parts(event : TraceEvent) : Array(String)
      parts = ["request", event.method || "-", event.path || event.route || "-"]
      parts << (event.status || "-").to_s
      parts << "#{ms(event.duration_ms)}ms"
      parts << "db=#{event.db_count}/#{ms(event.db_ms)}ms"
      parts << "view=#{ms(event.view_ms)}ms"
      event.action.try { |action| parts << action }
      event.request_id.try { |id| parts << "request_id=#{id}" }
      parts
    end

    private def self.job_parts(event : TraceEvent) : Array(String)
      parts = ["job", event.name]
      event.job_id.try { |id| parts << "##{id}" }
      parts << event.outcome
      parts << "#{ms(event.duration_ms)}ms"
      parts << "db=#{event.db_count}/#{ms(event.db_ms)}ms"
      event.queue.try { |queue| parts << "queue=#{queue}" }
      event.attempt.try { |attempt| parts << "attempt=#{attempt}" }
      event.queue_lag_ms.try { |lag| parts << "lag=#{ms(lag)}ms" }
      event.request_id.try { |id| parts << "request_id=#{id}" }
      parts
    end

    private def self.schedule_parts(event : TraceEvent) : Array(String)
      ["schedule", event.name, event.outcome, "#{ms(event.duration_ms)}ms",
       "db=#{event.db_count}/#{ms(event.db_ms)}ms"]
    end

    private def self.error_parts(event : ErrorEvent) : Array(String)
      parts = ["error", event.error_class, "fingerprint=#{event.fingerprint}"]
      event.location.try { |location| parts << "at #{location}" }
      event.source.try { |source| parts << "source=#{quote(source)}" }
      event.request_id.try { |id| parts << "request_id=#{id}" }
      event.message.try { |message| parts << "message=#{quote(message)}" }
      parts
    end

    def self.ms(value : Float64) : String
      "%.1f" % value
    end

    private def self.quote(value : String) : String
      return value unless value.includes?(' ') || value.includes?('"')

      "\"#{value.gsub('"', "\\\"")}\""
    end

    # The whole trace as Markdown, for a person, an agent or a bug report.
    # Sections with nothing to show are left out. *across* is what `across` made of the
    # spans Latte collected for this trace.
    def self.markdown(event : TraceEvent,
                      root : String? = nil,
                      across : Array(CollectedSpan) = [] of CollectedSpan) : String
      String.build do |io|
        io << "# " << inline(event.error.try(&.error_class) || event.name) << "\n\n"
        summary_list(io, event)
        error_section(io, event.error)
        backtrace_section(io, event.error, root)
        query_section(io, event)
        log_section(io, event)
        dump_section(io, event)
        across_section(io, across)
      end
    end

    # The spans Latte's collector holds for a trace, sorted by start, when any of them
    # came from a service other than *project*; empty when the trace stayed in one service.
    def self.across(spans : Array(CollectedSpan), project : String) : Array(CollectedSpan)
      return [] of CollectedSpan unless spans.any? { |span| span.service != project }

      spans.sort_by(&.start_unix_nano)
    end

    private def self.across_section(io : IO, spans : Array(CollectedSpan)) : Nil
      return if spans.empty?

      first = spans.first.start_unix_nano
      io << "\n## Across services\n\n"
      spans.each do |span|
        io << "- " << span.service << ": " << span.name << ", +"
        io << ms((span.start_unix_nano - first) / 1_000_000.0) << " ms, "
        io << ms(span_ms(span)) << " ms"
        io << ", error" if span.error?
        io << '\n'
      end
    end

    private def self.span_ms(span : CollectedSpan) : Float64
      (span.end_unix_nano - span.start_unix_nano) / 1_000_000.0
    end

    private def self.summary_list(io : IO, event : TraceEvent) : Nil
      io << "- kind: " << event.kind << "\n- name: " << inline(event.name) << '\n'
      event.status.try { |status| io << "- status: " << status << '\n' }
      io << "- duration: " << ms(event.duration_ms) << " ms\n"
      event.request_id.try { |id| io << "- request id: " << id << '\n' }
      io << "- trace id: " << event.trace_id << '\n'
      io << "- database: " << event.db_count << " queries, " << ms(event.db_ms) << " ms\n"
    end

    private def self.error_section(io : IO, error : ErrorEvent?) : Nil
      return unless error

      io << "\n## Error\n\n- class: " << inline(error.error_class) << '\n'
      error.message.try { |message| io << "- message: " << inline(message) << '\n' }
      error.location.try { |location| io << "- location: " << inline(location) << '\n' }
      io << "- causes: " << inline(error.causes.join(", ")) << '\n' unless error.causes.empty?
    end

    # *text* on one line, for a Markdown list item.
    private def self.inline(text : String) : String
      text.gsub(/[\r\n]+/, " ")
    end

    # *text* in a code fence longer than any run of backticks inside it.
    private def self.fenced(io : IO, text : String, language : String = "") : Nil
      longest = text.scan(/`+/).max_of?(&.[0].size) || 0
      fence = "`" * {3, longest + 1}.max
      io << fence << language << '\n' << text << '\n' << fence << '\n'
    end

    # Bind values and dumps may hold secrets; redact before they enter a report.
    private def self.scrubbed(text : String, limit : Int32) : String
      secrets = @@secrets ||= Redact.secrets
      Redact.text(text, secrets, limit)
    end

    private def self.backtrace_section(io : IO, error : ErrorEvent?, root : String?) : Nil
      frames = error.try(&.backtrace) || return
      return if frames.empty?

      ours, others = frames.partition { |frame| application_frame?(frame, root) }
      io << "\n## Backtrace\n\n"
      fenced(io, (ours + others).join('\n'))
    end

    private def self.query_section(io : IO, event : TraceEvent) : Nil
      queries = event.spans.select { |span| span.kind == "sql" }
      return if queries.empty?

      io << "\n## Queries\n"
      queries.each_with_index do |span, index|
        io << '\n' << index + 1 << ". " << ms(span.duration_ms) << " ms"
        span.rows.try { |rows| io << ", " << rows << " rows" }
        span.source.try { |source| io << ", " << inline(source) }
        io << "\n\n"
        fenced(io, span.detail || span.name, "sql")
        span.binds.try do |binds|
          next if binds.empty?

          shown = binds.map { |bind| scrubbed(bind, 200) }
          io << "\nbinds: " << inline(shown.inspect) << '\n'
        end
      end
    end

    private def self.log_section(io : IO, event : TraceEvent) : Nil
      logs = event.spans.select { |span| span.kind == "log" }
      return if logs.empty?

      io << "\n## Logs\n\n"
      logs.each do |span|
        io << "- [" << (span.level || "info") << "] " << inline(span.name) << '\n'
      end
    end

    private def self.dump_section(io : IO, event : TraceEvent) : Nil
      dumps = event.spans.select { |span| span.kind == "dump" }
      return if dumps.empty?

      io << "\n## Dumps\n"
      dumps.each do |span|
        io << '\n' << inline(span.name) << "\n\n"
        fenced(io, scrubbed(span.detail.to_s, 8192))
      end
    end

    # The trace as plain text: its line, its spans in order and its error.
    def self.detail(event : TraceEvent) : String
      String.build do |io|
        io << line(event) << '\n'
        io << "trace " << event.trace_id << '\n'
        event.spans.each { |span| span_text(io, span) }
        event.error.try { |error| error_text(io, error) }
      end
    end

    private def self.span_text(io : IO, span : SpanEvent) : Nil
      io << "  " << ms(span.offset_ms).rjust(8) << " ms  "
      io << span.kind << ' ' << ms(span.duration_ms) << " ms  "
      io << (span.detail || span.name).gsub(/\s+/, " ")
      span.source.try { |source| io << "  (" << source << ')' }
      io << '\n'
    end

    private def self.error_text(io : IO, error : ErrorEvent) : Nil
      io << "error " << error.error_class << '\n'
      error.message.try { |message| io << "  " << message << '\n' }
      error.backtrace.try(&.first(12).each { |frame| io << "    " << frame << '\n' })
    end

    # True for a backtrace line in the project's app, config, src or db.
    def self.application_frame?(text : String, root : String?) : Bool
      frame = Frames.parse(text) || return false
      return true if APPLICATION_DIRECTORIES.any? { |directory| frame.path.starts_with?(directory) }
      return false unless root

      Frames.application?(frame, root)
    end

    # The trace as an HTML fragment: summary, waterfall, queries, repeated
    # queries, logs, dumps, the error and a Copy as Markdown block. Source
    # locations become editor links when *editor* and *root* are given.
    def self.trace_html(event : TraceEvent,
                        editor : Editor?,
                        root : String?,
                        across : Array(CollectedSpan) = [] of CollectedSpan) : String
      String.build do |io|
        summary_html(io, event)
        waterfall_html(io, event)
        queries_html(io, event, editor, root)
        repeated_html(io, event)
        logs_html(io, event)
        dumps_html(io, event)
        error_html(io, event.error)
        across_html(io, across)
        markdown_html(io, event, root, across)
      end
    end

    # The "Across services" table: every collected span, labelled by service, with the same
    # SVG bars as the timeline.
    private def self.across_html(io : IO, spans : Array(CollectedSpan)) : Nil
      return if spans.empty?

      first = spans.min_of(&.start_unix_nano)
      total = {(spans.max_of(&.end_unix_nano) - first) / 1_000_000.0, 0.001}.max
      io << "<h3>Across services</h3><table class=\"waterfall across\"><tbody>"
      spans.each do |span|
        x = ((span.start_unix_nano - first) / 1_000_000.0 / total * 1000).round(1)
        width = {(span_ms(span) / total * 1000).round(1), 1.0}.max
        io << "<tr><td>" << HTML.escape(span.service) << "</td><td>" << HTML.escape(span.name)
        io << "</td><td>" << ms(span_ms(span)) << " ms</td><td>"
        io << "<svg viewBox=\"0 0 1000 8\" class=\"bar" << (span.error? ? " error" : "")
        io << "\"><rect x=\"" << x << "\" width=\"" << width << "\" height=\"8\"/></svg>"
        io << "</td></tr>"
      end
      io << "</tbody></table>"
    end

    private def self.summary_html(io : IO, event : TraceEvent) : Nil
      io << "<h2>" << HTML.escape(event.name) << "</h2><dl class=\"summary\">"
      pair(io, "Kind", event.kind)
      pair(io, "Outcome", event.outcome)
      pair(io, "Status", event.status.to_s) if event.status
      pair(io, "Duration", "#{ms(event.duration_ms)} ms")
      pair(io, "Queries", "#{event.db_count} in #{ms(event.db_ms)} ms")
      pair(io, "Views", "#{ms(event.view_ms)} ms")
      pair(io, "Outbound calls", "#{event.outbound_count} in #{ms(event.outbound_ms)} ms")
      pair(io, "Request id", event.request_id.to_s) if event.request_id
      pair(io, "Trace id", event.trace_id)
      io << "</dl>"
    end

    private def self.pair(io : IO, name : String, value : String) : Nil
      io << "<dt>" << HTML.escape(name) << "</dt><dd>" << HTML.escape(value) << "</dd>"
    end

    # One row per span; each bar is an SVG, because the inspector's CSP
    # forbids inline styles.
    private def self.waterfall_html(io : IO, event : TraceEvent) : Nil
      return if event.spans.empty?

      ends = event.spans.max_of { |span| span.offset_ms + span.duration_ms }
      total = {event.duration_ms, ends, 0.001}.max
      io << "<h3>Timeline</h3><table class=\"waterfall\"><tbody>"
      event.spans.each do |span|
        x = (span.offset_ms / total * 1000).round(1)
        width = {(span.duration_ms / total * 1000).round(1), 1.0}.max
        io << "<tr><td>" << HTML.escape(span.kind) << "</td><td>" << HTML.escape(span.name)
        io << "</td><td>" << ms(span.duration_ms) << " ms</td><td>"
        io << "<svg viewBox=\"0 0 1000 8\" class=\"bar\"><rect x=\"" << x
        io << "\" width=\"" << width << "\" height=\"8\"/></svg></td></tr>"
      end
      io << "</tbody></table>"
    end

    private def self.queries_html(io : IO,
                                  event : TraceEvent,
                                  editor : Editor?,
                                  root : String?) : Nil
      queries = event.spans.select { |span| span.kind == "sql" }
      return if queries.empty?

      io << "<h3>Queries</h3><table class=\"queries\"><thead><tr><th>Time</th><th>SQL</th>"
      io << "<th>Binds</th><th>Source</th></tr></thead><tbody>"
      queries.each do |span|
        io << "<tr><td>" << ms(span.duration_ms) << " ms</td><td><pre>"
        io << HTML.escape(span.detail || span.name) << "</pre></td><td>"
        span.binds.try { |binds| io << HTML.escape(binds.inspect) }
        io << "</td><td>" << source_link(span.source, editor, root) << "</td></tr>"
      end
      io << "</tbody></table>"
    end

    # *source* (`app/x.cr:12:7`) as an editor link, plain text without one.
    def self.source_link(source : String?, editor : Editor?, root : String?) : String
      return "" unless source

      text = HTML.escape(source)
      return text unless editor && root

      path, line, column = split_source(source)
      href = editor.link(File.join(root, path), line, column)
      href.empty? ? text : "<a class=\"editor\" href=\"#{HTML.escape(href)}\">#{text}</a>"
    end

    # `path:line:column` as its three parts.
    def self.split_source(source : String) : {String, Int32, Int32}
      parts = source.split(':')
      column = parts.size > 2 ? parts.last.to_i? : nil
      line = parts.size > 1 ? parts[column ? -2 : -1].to_i? : nil
      count = column ? 2 : (line ? 1 : 0)
      {parts[0, parts.size - count].join(':'), line || 1, column || 1}
    end

    private def self.repeated_html(io : IO, event : TraceEvent) : Nil
      event.repeated.each do |repeat|
        io << "<p class=\"warning\">Ran " << repeat.count << " times: <code>"
        io << HTML.escape(repeat.sql) << "</code></p>"
      end
    end

    private def self.logs_html(io : IO, event : TraceEvent) : Nil
      logs = event.spans.select { |span| span.kind == "log" }
      return if logs.empty?

      io << "<h3>Logs</h3><ul class=\"logs\">"
      logs.each do |span|
        io << "<li class=\"" << HTML.escape(span.level || "info") << "\">"
        io << HTML.escape(span.name) << "</li>"
      end
      io << "</ul>"
    end

    private def self.dumps_html(io : IO, event : TraceEvent) : Nil
      dumps = event.spans.select { |span| span.kind == "dump" }
      return if dumps.empty?

      io << "<h3>Dumps</h3>"
      dumps.each do |span|
        io << "<p><code>" << HTML.escape(span.name) << "</code></p><pre>"
        io << HTML.escape(span.detail.to_s) << "</pre>"
      end
    end

    private def self.error_html(io : IO, error : ErrorEvent?) : Nil
      return unless error

      io << "<h3>Error</h3><p><strong>" << HTML.escape(error.error_class) << "</strong>"
      error.location.try { |location| io << " at <code>" << HTML.escape(location) << "</code>" }
      io << "</p>"
      error.message.try { |message| io << "<pre>" << HTML.escape(message) << "</pre>" }
    end

    private def self.markdown_html(io : IO,
                                   event : TraceEvent,
                                   root : String?,
                                   across : Array(CollectedSpan)) : Nil
      io << "<details class=\"markdown\"><summary>Copy as Markdown</summary>"
      io << "<pre id=\"caramel-markdown\">" << HTML.escape(markdown(event, root, across))
      io << "</pre>"
      io << "<button type=\"button\" data-caramel-copy=\"caramel-markdown\">"
      io << "Copy as Markdown</button></details>"
    end

    # A table of *events*, newest first; each name links to
    # `link_prefix + trace id`.
    def self.traces_table_html(events : Array(TraceEvent), link_prefix : String) : String
      return "<p>No requests yet.</p>" if events.empty?

      String.build do |io|
        io << "<table class=\"traces\"><thead><tr><th>Time</th><th>Kind</th><th>Name</th>"
        io << "<th>Status</th><th>Duration</th><th>Queries</th><th>Flags</th></tr></thead><tbody>"
        events.each { |event| trace_row(io, event, link_prefix) }
        io << "</tbody></table>"
      end
    end

    private def self.trace_row(io : IO, event : TraceEvent, link_prefix : String) : Nil
      at = event.started_at
      io << "<tr><td>" << HTML.escape(at[11, 8]? || at) << "</td><td>"
      io << HTML.escape(event.kind) << "</td><td><a href=\"" << HTML.escape(link_prefix)
      io << HTML.escape(event.trace_id) << "\">" << HTML.escape(event.name) << "</a></td><td>"
      io << (event.status || event.outcome) << "</td><td>"
      io << ms(event.duration_ms) << " ms</td><td>"
      io << event.db_count << "</td><td>" << flags(event).join(' ') << "</td></tr>"
    end

    private def self.flags(event : TraceEvent) : Array(String)
      flags = [] of String
      flags << "error" if event.outcome == "error"
      flags << "slow" if event.slow?
      flags << "repeated" unless event.repeated.empty?
      flags << "debug" if event.debug?
      flags
    end
  end
end
