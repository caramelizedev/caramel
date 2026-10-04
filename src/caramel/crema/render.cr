require "../html"
require "./editor"
require "./event"
require "./frames"

module Caramel::Crema
  # Pure functions over the wire-format events, shared by `ops tail`,
  # `frappe traces`, the ops console and the development inspector. They
  # take events, not live objects, so Frappé and Latte can use them.
  module Render
    APPLICATION_DIRECTORIES = {"app/", "config/", "src/", "db/"}

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
    # Sections with nothing to show are left out.
    def self.markdown(event : TraceEvent, root : String? = nil) : String
      String.build do |io|
        io << "# " << (event.error.try(&.error_class) || event.name) << "\n\n"
        summary_list(io, event)
        error_section(io, event.error)
        backtrace_section(io, event.error, root)
        query_section(io, event)
        log_section(io, event)
        dump_section(io, event)
      end
    end

    private def self.summary_list(io : IO, event : TraceEvent) : Nil
      io << "- kind: " << event.kind << "\n- name: " << event.name << '\n'
      event.status.try { |status| io << "- status: " << status << '\n' }
      io << "- duration: " << ms(event.duration_ms) << " ms\n"
      event.request_id.try { |id| io << "- request id: " << id << '\n' }
      io << "- trace id: " << event.trace_id << '\n'
      io << "- database: " << event.db_count << " queries, " << ms(event.db_ms) << " ms\n"
    end

    private def self.error_section(io : IO, error : ErrorEvent?) : Nil
      return unless error

      io << "\n## Error\n\n- class: " << error.error_class << '\n'
      error.message.try { |message| io << "- message: " << message << '\n' }
      error.location.try { |location| io << "- location: " << location << '\n' }
      io << "- causes: " << error.causes.join(", ") << '\n' unless error.causes.empty?
    end

    private def self.backtrace_section(io : IO, error : ErrorEvent?, root : String?) : Nil
      frames = error.try(&.backtrace) || return
      return if frames.empty?

      ours, others = frames.partition { |frame| application_frame?(frame, root) }
      io << "\n## Backtrace\n\n```\n"
      (ours + others).each { |frame| io << frame << '\n' }
      io << "```\n"
    end

    private def self.query_section(io : IO, event : TraceEvent) : Nil
      queries = event.spans.select { |span| span.kind == "sql" }
      return if queries.empty?

      io << "\n## Queries\n"
      queries.each_with_index do |span, index|
        io << '\n' << index + 1 << ". " << ms(span.duration_ms) << " ms"
        span.rows.try { |rows| io << ", " << rows << " rows" }
        span.source.try { |source| io << ", " << source }
        io << "\n\n```sql\n" << (span.detail || span.name) << "\n```\n"
        span.binds.try { |binds| io << "\nbinds: " << binds.inspect << '\n' unless binds.empty? }
      end
    end

    private def self.log_section(io : IO, event : TraceEvent) : Nil
      logs = event.spans.select { |span| span.kind == "log" }
      return if logs.empty?

      io << "\n## Logs\n\n"
      logs.each { |span| io << "- [" << (span.level || "info") << "] " << span.name << '\n' }
    end

    private def self.dump_section(io : IO, event : TraceEvent) : Nil
      dumps = event.spans.select { |span| span.kind == "dump" }
      return if dumps.empty?

      io << "\n## Dumps\n"
      dumps.each { |span| io << "\n" << span.name << "\n\n```\n" << span.detail << "\n```\n" }
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
    def self.trace_html(event : TraceEvent, editor : Editor?, root : String?) : String
      String.build do |io|
        summary_html(io, event)
        waterfall_html(io, event)
        queries_html(io, event, editor, root)
        repeated_html(io, event)
        logs_html(io, event)
        dumps_html(io, event)
        error_html(io, event.error)
        markdown_html(io, event, root)
      end
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

    private def self.markdown_html(io : IO, event : TraceEvent, root : String?) : Nil
      io << "<details class=\"markdown\"><summary>Copy as Markdown</summary>"
      io << "<pre id=\"caramel-markdown\">" << HTML.escape(markdown(event, root)) << "</pre>"
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
      io << "<tr><td>" << HTML.escape(event.started_at[11, 8]) << "</td><td>"
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
