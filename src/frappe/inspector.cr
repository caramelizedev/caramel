require "json"
require "./dev_events"
require "../caramel/html"
require "../caramel/response"
require "../caramel/crema/render"

module Caramel::Frappe
  # The development inspector (ADR 0027): recent requests and jobs, their
  # queries, the errors grouped by fingerprint and Frappé's builds, served by
  # the gateway under `/__caramel/dev/inspector` from the session's events.
  class Inspector
    PREFIX  = "/__caramel/dev/inspector"
    TRACES  = "#{PREFIX}/traces/"
    FILTERS = {
      "errors" => ->(event : Crema::TraceEvent) { event.outcome == "error" },
      "slow"   => ->(event : Crema::TraceEvent) { event.slow? },
      "jobs"   => ->(event : Crema::TraceEvent) { event.kind != "request" },
    }
    NAV = {
      "Requests" => PREFIX,
      "Errors"   => "#{PREFIX}/errors",
      "Builds"   => "#{PREFIX}/builds",
    }

    def initialize(@events : DevEvents,
                   @editor : Crema::Editor,
                   @root : String,
                   @collected : Crema::CollectedLookup = Crema::NO_COLLECTED)
    end

    def response(request : HTTP::Request) : Caramel::Response
      path = request.path
      case
      when path == PREFIX             then list(request)
      when path.starts_with?(TRACES)  then detail(path.lchop(TRACES))
      when path == "#{PREFIX}/errors" then errors
      when path == "#{PREFIX}/builds" then builds
      else                                 missing("Nothing at this address.")
      end
    end

    # The JSON the toolbar and the list page poll: traces newer than `after`, or
    # the traces of one `request` id.
    def feed(request : HTTP::Request) : String
      params = request.query_params
      after = params["after"]?.try(&.to_i64?) || 0_i64
      limit = (params["limit"]?.try(&.to_i?) || 50).clamp(1, 500)
      wanted = params["request"]?
      entries = @events.traces(after, wanted ? EventStore::MAX_TRACES : limit)
      entries = entries.select { |_, event| event.request_id == wanted } if wanted
      JSON.build do |json|
        json.object do
          json.field "latest", @events.latest
          json.field "traces" do
            json.array { entries.each { |seq, event| summary(json, seq, event) } }
          end
        end
      end
    end

    private def summary(json : JSON::Builder, seq : Int64, event : Crema::TraceEvent) : Nil
      json.object do
        json.field "seq", seq
        json.field "trace_id", event.trace_id
        json.field "request_id", event.request_id
        json.field "kind", event.kind
        json.field "name", event.name
        json.field "status", event.status
        json.field "duration_ms", event.duration_ms
        json.field "db_count", event.db_count
        json.field "outcome", event.outcome
        json.field "repeated", event.repeated.size
        json.field "slow", event.slow?
      end
    end

    private def list(request : HTTP::Request) : Caramel::Response
      only = request.query_params["only"]?
      events = @events.traces(0, EventStore::MAX_TRACES).map(&.[1])
      filter = only.try { |name| FILTERS[name]? }
      events = events.select { |event| filter.call(event) } if filter
      body = "<p class=\"new\" data-caramel-new hidden>New requests have arrived. " \
             "<a href=\"#{PREFIX}\">Reload</a></p>" \
             "<p class=\"filters\">#{filter_links(only)}</p>" \
             "#{Crema::Render.traces_table_html(events, TRACES)}"
      page("Requests", body)
    end

    private def filter_links(current : String?) : String
      links = ["<a href=\"#{PREFIX}\">All</a>"]
      FILTERS.each_key do |name|
        marker = name == current ? " aria-current=\"page\"" : ""
        links << "<a href=\"#{PREFIX}?only=#{name}\"#{marker}>#{name.capitalize}</a>"
      end
      links.join(" · ")
    end

    private def detail(id : String) : Caramel::Response
      event = @events.find(id)
      return missing("No request or job matches #{id}.") unless event

      across = @collected.call(event.trace_id)
      page(event.name, Crema::Render.trace_html(event, @editor, @root, across))
    end

    # Error events grouped by fingerprint, newest group first.
    private def errors : Caramel::Response
      groups = @events.errors.group_by(&.fingerprint)
      if groups.empty?
        return page("Errors", "<p>No errors since this session started.</p>")
      end
      newest = groups.values.sort_by!(&.last.at).reverse!
      rows = newest.join { |group| error_row(group) }
      table = "<table><thead><tr><th>Count</th><th>Last seen</th><th>Error</th><th>Where</th>" \
              "<th>Trace</th></tr></thead><tbody>#{rows}</tbody></table>"
      page("Errors", table)
    end

    private def error_row(group : Array(Crema::ErrorEvent)) : String
      newest = group.last
      where = Crema::Render.source_link(newest.location, @editor, @root)
      "<tr><td>#{group.size}</td><td>#{Caramel::HTML.escape(clock(newest.at))}</td>" \
      "<td>#{Caramel::HTML.escape(newest.error_class)}</td><td>#{where}</td>" \
      "<td>#{trace_link(newest)}</td></tr>"
    end

    private def trace_link(error : Crema::ErrorEvent) : String
      id = error.trace_id || return ""
      "<a href=\"#{TRACES}#{Caramel::HTML.escape(id)}\">#{Caramel::HTML.escape(id[0, 8])}</a>"
    end

    private def builds : Caramel::Response
      entries = @events.builds.reverse
      return page("Builds", "<p>No builds since this session started.</p>") if entries.empty?

      page("Builds", entries.join { |event| build(event) })
    end

    private def build(event : Crema::BuildEvent) : String
      diagnostics = event.diagnostics.join { |item| diagnostic(item) }
      message = event.message.try { |text| "<pre>#{Caramel::HTML.escape(text)}</pre>" }
      state = Caramel::HTML.escape(event.state)
      "<section class=\"build #{state}\"><h2>#{Caramel::HTML.escape(event.state.capitalize)}" \
      " <small>#{Crema::Render.ms(event.duration_ms)} ms · " \
      "#{Caramel::HTML.escape(clock(event.at))}" \
      "</small></h2>#{diagnostics}#{message}</section>"
    end

    # The `HH:MM:SS` of an RFC 3339 time, or dashes when it is shorter.
    private def clock(at : String) : String
      at.size >= 19 ? at[11, 8] : "--:--:--"
    end

    private def diagnostic(item : Crema::BuildDiagnostic) : String
      location = Caramel::HTML.escape("#{item.file}:#{item.line}:#{item.column}")
      path = item.file.starts_with?("/") ? item.file : File.join(@root, item.file)
      href = @editor.link(path, item.line, item.column)
      link = href.empty? ? location : "<a href=\"#{Caramel::HTML.escape(href)}\">#{location}</a>"
      fix = item.remediation.try { |text| "<p>#{Caramel::HTML.escape(text)}</p>" }
      "<article class=\"diagnostic\">#{link}<p>#{Caramel::HTML.escape(item.message)}</p>" \
      "#{fix}</article>"
    end

    private def missing(message : String) : Caramel::Response
      response = page("Not found", "<p>#{Caramel::HTML.escape(message)}</p>")
      Caramel::Response.new(404, response.body, response.headers)
    end

    private def page(title : String, body : String) : Caramel::Response
      nav = NAV.join(" ") { |name, href| "<a href=\"#{href}\">#{name}</a>" }
      html = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">" \
             "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" \
             "<meta name=\"color-scheme\" content=\"light dark\">" \
             "<title>#{Caramel::HTML.escape(title)} · Frappé inspector</title>" \
             "<script src=\"/__caramel/dev/theme.js\"></script>" \
             "<link rel=\"stylesheet\" href=\"/__caramel/dev/inspector.css\"></head>" \
             "<body><header><strong>FRAPPÉ INSPECTOR</strong><nav>#{nav}</nav>" \
             "<button type=\"button\" class=\"theme\" data-caramel-theme " \
             "title=\"Colour theme: click to change\">Theme: auto</button></header>" \
             "<main><h1>#{Caramel::HTML.escape(title)}</h1>#{body}</main></body></html>"
      headers = HTTP::Headers{"Content-Type" => "text/html; charset=utf-8"}
      Caramel::Response.new(200, html, headers)
    end
  end
end
