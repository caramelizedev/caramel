require "json"
require "./crema"
require "./crema/editor"
require "./crema/render"
require "./html"
require "./response"

module Caramel
  # Application requires this file only in a development build. Runtime mode
  # is checked separately so a development binary cannot expose details when
  # accidentally started with production configuration.
  module DevelopmentError
    NO_APPLICATION_FRAME = "<p>No application frame was available. " \
                           "Expand the stack below for the failing dependency.</p>"
    NEXT_STEP = "<p>Check the first application frame, fix the failing operation, " \
                "and save your changes. Frappé will rebuild the application.</p>"
    MAX_SOURCE_FILE = 1_048_576
    SOURCE_CONTEXT  =         4

    def self.response(error : Exception,
                      report : Crema::ErrorReport,
                      request : HTTP::Request) : Response
      return json_response(error, report) if prefers_json?(request)

      page = Page.new(error, report, request)
      title = "<title>#{HTML.escape(error.class.to_s)} · Caramel development</title>"
      full = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">" \
             "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" \
             "#{title}<link rel=\"stylesheet\" href=\"/__caramel/dev/style.css\"></head>" \
             "<body><main>#{page.content}</main></body></html>"
      response = Response.html(request, full: full, partial: title + page.content, status: 500)
      response.headers["X-Request-ID"] = report.request_id || ""
      response.headers["Cache-Control"] = "no-store"
      response
    end

    # True when the client lists JSON before HTML, such as `fetch` or an API client.
    private def self.prefers_json?(request : HTTP::Request) : Bool
      accept = request.headers["Accept"]? || return false
      json = accept.index("application/json") || return false
      html = accept.index("text/html")
      html.nil? || json < html
    end

    private def self.json_response(error : Exception, report : Crema::ErrorReport) : Response
      secrets = Crema.secrets
      body = JSON.build do |json|
        json.object do
          json.field "error" do
            json.object do
              json.field "class", error.class.to_s
              json.field "message", Crema::Redact.text(error.message || "", secrets, 8192)
              json.field "location", report.location
              json.field "request_id", report.request_id
              json.field "trace_id", report.trace_id
              json.field "backtrace", report.backtrace
            end
          end
        end
      end
      headers = HTTP::Headers{
        "Content-Type"  => "application/json; charset=utf-8",
        "X-Request-ID"  => report.request_id || "",
        "Cache-Control" => "no-store",
      }
      Response.new(500, body, headers)
    end

    # The HTML of one error page.
    private struct Page
      getter content : String

      def initialize(@error : Exception, @report : Crema::ErrorReport, @request : HTTP::Request)
        @root = Crema::Frames.root
        @secrets = Crema.secrets
        @editor = Crema::Editor.from(ENV["CARAMEL_EDITOR"]?)
        @content = String.build { |io| write(io) }
      end

      private def write(io : IO) : Nil
        frames = @error.backtrace?.try(&.first(80)) || [] of String
        application, internal = frames.partition { |frame| application?(frame) }
        io << "<section class=\"development-error\"><p>CARAMEL DEVELOPMENT EXCEPTION</p>"
        io << "<h1>" << HTML.escape(@error.class.to_s) << "</h1><pre>"
        io << HTML.escape(redact(@error.message || "No exception message", 8192)) << "</pre>"
        io << "<h2>Application location</h2>"
        write_location(io, application)
        io << NEXT_STEP
        write_source(io, application.first?)
        write_request(io)
        write_queries(io)
        write_causes(io)
        io << "<details><summary>Internal stack frames</summary><ol>"
        internal.each { |frame| write_frame(io, frame, false) }
        io << "</ol></details>"
        write_markdown(io)
        io << "<p>Request reference: <code>" << HTML.escape(@report.request_id || "")
        io << "</code></p></section>"
      end

      private def application?(frame : String) : Bool
        parsed = Crema::Frames.parse(frame)
        parsed ? Crema::Frames.application?(parsed, @root) : false
      end

      private def write_location(io : IO, application : Array(String)) : Nil
        return io << NO_APPLICATION_FRAME if application.empty?

        io << "<ol>"
        application.each { |frame| write_frame(io, frame, true) }
        io << "</ol>"
      end

      private def write_frame(io : IO, frame : String, editable : Bool) : Nil
        shown = frame.gsub(@root + "/", "")
        io << "<li><code>" << HTML.escape(redact(shown, 2048)) << "</code>"
        io << editor_link(frame) if editable
        io << "</li>"
      end

      private def editor_link(frame : String) : String
        parsed = Crema::Frames.parse(frame) || return ""
        path = File.expand_path(parsed.path, Process::INITIAL_PWD || Dir.current)
        href = @editor.link(path, parsed.line, parsed.column || 1)
        return "" if href.empty?

        " <a class=\"editor\" href=\"#{HTML.escape(href)}\">Open in editor</a>"
      end

      # A few lines around the failing one, when the file belongs to the project.
      private def write_source(io : IO, frame : String?) : Nil
        parsed = frame.try { |text| Crema::Frames.parse(text) } || return
        lines = source_lines(parsed) || return
        first = {parsed.line - SOURCE_CONTEXT, 1}.max
        last = {parsed.line + SOURCE_CONTEXT, lines.size}.min
        return if first > last

        io << "<figure class=\"source\"><figcaption>"
        io << HTML.escape(Crema::Frames.relative(parsed.path, @root)) << ':' << parsed.line
        io << "</figcaption><pre><code>"
        (first..last).each { |number| write_line(io, number, lines[number - 1], parsed.line) }
        io << "</code></pre></figure>"
      end

      private def write_line(io : IO, number : Int32, text : String, failing : Int32) : Nil
        shown = "#{number.to_s.rjust(4)}  #{HTML.escape(redact(text, 1000))}\n"
        io << (number == failing ? "<mark>#{shown}</mark>" : shown)
      end

      # The file's lines, or nil unless it is a small file inside app, config, src or db.
      private def source_lines(frame : Crema::Frame) : Array(String)?
        path = File.expand_path(frame.path, Process::INITIAL_PWD || Dir.current)
        real = File.realpath(path)
        root = File.realpath(@root)
        inside = Crema::Frames::DIRECTORIES.any? { |name| real.starts_with?("#{root}/#{name}/") }
        return unless inside && File.size(real) <= MAX_SOURCE_FILE

        File.read_lines(real)
      rescue File::Error
        nil
      end

      private def write_request(io : IO) : Nil
        trace = Crema.current?
        io << "<h2>Request</h2><dl>"
        pair(io, "Method", @request.method)
        pair(io, "Path", trace.try(&.path) || @request.path)
        pair(io, "Route", trace.try(&.route) || "(none)")
        pair(io, "Action", trace.try(&.action) || "(none)")
        pair(io, "Request id", @report.request_id || "")
        pair(io, "Trace id", @report.trace_id || "")
        pair(io, "HX-Request-Type", @request.headers["HX-Request-Type"]? || "")
        io << "</dl>"
      end

      private def pair(io : IO, name : String, value : String) : Nil
        io << "<dt>" << HTML.escape(name) << "</dt><dd>" << HTML.escape(value) << "</dd>"
      end

      private def write_queries(io : IO) : Nil
        io << "<h2>Queries before the error</h2>"
        trace = Crema.current?
        queries = trace.try(&.to_event(Crema::Detail::Development).spans.select(&.kind.==("sql")))
        if queries.nil? || queries.empty?
          ran = trace && trace.db_count > 0
          io << (ran && trace ? unrecorded(trace.db_count) : "<p>No queries ran.</p>")
          return
        end
        io << "<ol class=\"queries\">"
        queries.each { |span| write_query(io, span) }
        io << "</ol>"
      end

      private def unrecorded(count : Int32) : String
        "<p>#{count} queries ran; their text is recorded while Frappé's inspector is attached.</p>"
      end

      private def write_query(io : IO, span : Crema::SpanEvent) : Nil
        io << "<li>" << Crema::Render.ms(span.duration_ms) << " ms <code>"
        io << HTML.escape(redact(span.detail || span.name, 2000)) << "</code>"
        span.binds.try { |binds| io << " <small>" << HTML.escape(binds.inspect) << "</small>" }
        link = Crema::Render.source_link(span.source, @editor, @root)
        io << ' ' << link unless link.empty?
        io << "</li>"
      end

      private def write_causes(io : IO) : Nil
        cause = @error.cause || return
        io << "<h2>Caused by</h2><ul>"
        while cause
          io << "<li>" << HTML.escape(cause.class.to_s) << ": "
          io << HTML.escape(redact(cause.message || "", 2048)) << "</li>"
          cause = cause.cause
        end
        io << "</ul>"
      end

      private def write_markdown(io : IO) : Nil
        trace = Crema.current? || return
        text = Crema::Render.markdown(trace.to_event(Crema::Detail::Development), @root)
        io << "<details class=\"markdown\"><summary>Copy as Markdown</summary>"
        io << "<pre id=\"caramel-markdown\">" << HTML.escape(text) << "</pre>"
        io << "<button type=\"button\" data-caramel-copy=\"caramel-markdown\">"
        io << "Copy as Markdown</button></details>"
      end

      private def redact(text : String, limit : Int32) : String
        Crema::Redact.text(text, @secrets, limit)
      end
    end
  end
end
