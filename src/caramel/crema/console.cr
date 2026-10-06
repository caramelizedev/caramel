require "http/server"
require "../html"
require "./diagnose"
require "./jobs"
require "./render"
require "./runtime"

module Caramel::Crema
  @@pages = {} of String => Proc(HTTP::Request, String)

  # Adds a console page at `/<segment>` whose body *block* returns as HTML. The
  # opt-in recorder registers `insights` this way.
  def self.console_page(segment : String, &block : HTTP::Request -> String) : Nil
    @@pages[segment] = block
  end

  def self.console_pages : Hash(String, Proc(HTTP::Request, String))
    @@pages
  end

  # The read-only HTML console the ops socket serves. It shows what the JSON API
  # shows; it changes nothing. Its pages load only their own stylesheet and script,
  # and the Live tail page streams `/v1/tail`.
  module Console
    CSS = {{ read_file("#{__DIR__}/console.css") }}
    JS  = {{ read_file("#{__DIR__}/console.js") }}

    POLICY = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; " \
             "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'"
    SINCE = "Since this process started; restarts clear it."
    NAV   = {
      "Overview" => "/", "In flight" => "/requests", "Live tail" => "/tail", "Jobs" => "/jobs",
      "Database" => "/database", "Errors" => "/errors", "Traces" => "/traces",
      "Insights" => "/insights",
    }
    RECORDER_OFF = "<p>The Crema recorder is off. Add " \
                   "<code>require \"caramel/crema/recorder\"</code> to config/application.cr.</p>"

    def self.routes(ops : Ops) : Hash(String, Ops::Route)
      {
        "GET /"            => page(ops, "Overview", "/") { overview(ops) },
        "GET /requests"    => page(ops, "In flight", "/requests") { in_flight },
        "GET /tail"        => page(ops, "Live tail", "/tail") { tail },
        "GET /jobs"        => page(ops, "Jobs", "/jobs") { jobs(ops) },
        "GET /database"    => page(ops, "Database", "/database") { database(ops) },
        "GET /errors"      => page(ops, "Errors", "/errors") { errors(ops) },
        "GET /traces"      => page(ops, "Traces", "/traces") { traces(ops) },
        "GET /insights"    => insights(ops),
        "GET /console.css" => asset(ops, CSS, "text/css; charset=utf-8"),
        "GET /console.js"  => asset(ops, JS, "text/javascript; charset=utf-8"),
      }
    end

    # The console routes whose path ends in an identifier.
    def self.prefixed(ops : Ops, path : String) : Ops::Route?
      if path.starts_with?("/errors/")
        fingerprint = path.lchop("/errors/")
        page(ops, "Error #{fingerprint}", "/errors") { error_detail(ops, fingerprint) }
      elsif path.starts_with?("/traces/")
        ref = path.lchop("/traces/")
        page(ops, "Trace #{ref}", "/traces") { trace_detail(ops, ref) }
      end
    end

    def self.not_found(ops : Ops, context : HTTP::Server::Context) : Nil
      html(ops, context, 404, layout("Not found", "", "<p>Nothing is here.</p>"))
    end

    private def self.page(ops : Ops,
                          title : String,
                          active : String,
                          &block : -> String) : Ops::Route
      ->(context : HTTP::Server::Context) do
        html(ops, context, 200, layout(title, active, block.call))
      end
    end

    private def self.asset(ops : Ops, body : String, type : String) : Ops::Route
      ->(context : HTTP::Server::Context) { ops.respond(context, 200, type, body) }
    end

    private def self.html(ops : Ops,
                          context : HTTP::Server::Context,
                          status : Int32,
                          body : String) : Nil
      context.response.headers["Content-Security-Policy"] = POLICY
      ops.respond(context, status, "text/html; charset=utf-8", body)
    end

    private def self.insights(ops : Ops) : Ops::Route
      ->(context : HTTP::Server::Context) do
        page = Crema.console_pages["insights"]?
        body = page ? page.call(context.request) : RECORDER_OFF
        html(ops, context, 200, layout("Insights", "/insights", body))
      end
    end

    def self.layout(title : String, active : String, body : String) : String
      nav = NAV.join(" ") do |name, href|
        current = href == active ? " aria-current=\"page\"" : ""
        "<a href=\"#{href}\"#{current}>#{name}</a>"
      end
      "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">" \
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" \
      "<title>#{HTML.escape(title)} · Crema</title>" \
      "<link rel=\"stylesheet\" href=\"/console.css\"></head><body>" \
      "<header><strong>CREMA</strong><nav>#{nav}</nav></header>" \
      "<main><h1>#{HTML.escape(title)}</h1>#{body}</main>" \
      "<script src=\"/console.js\" defer></script></body></html>"
    end

    private def self.overview(ops : Ops) : String
      runtime = ops.runtime
      facts = String.build do |io|
        io << "<dl class=\"facts\">"
        fact(io, "App", "#{runtime.app} · caramel #{Caramel::VERSION} · #{runtime.role}")
        fact(io, "Up since", runtime.started_at.to_rfc3339)
        fact(io, "In flight", Crema.in_flight.size.to_s)
        fact(io, "Fibers", Crema.fiber_count.to_s)
        fact(io, "Sinks", Crema.sinks.map(&.name).join(", "))
        dropped = Crema.dropped.to_a.join(", ") { |name, count| "#{name} #{count}" }
        fact(io, "Dropped", dropped.presence || "0")
        runtime.pools.each do |pool|
          fact(io, "Pool #{pool.name}", "#{pool.open}/#{pool.max} open, #{pool.in_flight} in use")
        end
        io << "</dl>"
      end
      facts + routes_table
    end

    private def self.fact(io : IO, name : String, value : String) : Nil
      io << "<dt>" << HTML.escape(name) << "</dt><dd>" << HTML.escape(value) << "</dd>"
    end

    # Requests since start, by route: count, errors, p50, p95 and the slowest.
    private def self.routes_table : String
      rows = [] of Array(String)
      Crema.metrics.durations.each do |kind, key, entry|
        next unless kind == "request"

        histogram = entry.histogram
        rows << [key, entry.count.to_s, entry.errors.to_s,
                 Render.ms(histogram.quantile(0.5, entry.max_ms)),
                 Render.ms(histogram.quantile(0.95, entry.max_ms)), Render.ms(entry.max_ms)]
      end
      rows.sort_by! { |row| -row[1].to_i }
      table = Table.new(%w[Route Count Errors P50\ ms P95\ ms Max\ ms], rows)
      "<h2>Routes</h2>#{table.to_html}<p>#{SINCE}</p>"
    end

    private def self.in_flight : String
      rows = Crema.in_flight.map do |trace|
        [trace.kind.wire, trace.name, trace.request_id.to_s, Render.ms(Trace.ms(trace.elapsed)),
         trace.db_count.to_s]
      end
      Table.new(%w[Kind Name Request\ id Elapsed\ ms Queries], rows).to_html
    end

    private def self.tail : String
      "<p>Newest first. Errors are red.</p><ol id=\"tail\" class=\"tail\"></ol>"
    end

    private def self.jobs(ops : Ops) : String
      db = ops.runtime.database
      return "<p>This process has no database.</p>" unless db

      "<h2>Queues</h2>#{Jobs.stats(db).to_html}<h2>Failed</h2>#{Jobs.failed(20, db).to_html}"
    rescue error
      "<p>Jobs are unavailable (#{HTML.escape(error.class.to_s)}).</p>"
    end

    private def self.database(ops : Ops) : String
      db = ops.runtime.database
      return "<p>This process has no database.</p>" unless db

      Diagnose.sections(db).join do |section|
        "<h2>#{HTML.escape(section.name)}</h2><pre>#{HTML.escape(section.text)}</pre>"
      end
    end

    private def self.errors(ops : Ops) : String
      entries = ops.errors.entries
      return "<p>No errors.</p><p>#{SINCE}</p>" if entries.empty?

      rows = entries.map do |entry|
        fingerprint = HTML.escape(entry.fingerprint)
        link = "<a href=\"/errors/#{fingerprint}\">#{fingerprint}</a>"
        [link, entry.count.to_s, entry.last_seen.to_rfc3339, entry.report.error_class,
         entry.report.location.to_s, entry.report.source.to_s]
      end
      table = Table.new(%w[Fingerprint Count Last\ seen Class Location Source], rows)
      "#{linked(table)}<p>#{SINCE}</p>"
    end

    # A table whose first column already holds HTML.
    private def self.linked(table : Table) : String
      head = table.headers.join { |name| "<th>#{HTML.escape(name)}</th>" }
      body = table.rows.join do |row|
        cells = row.each_with_index.join do |cell, index|
          "<td>#{index == 0 ? cell : HTML.escape(cell)}</td>"
        end
        "<tr>#{cells}</tr>"
      end
      "<table><thead><tr>#{head}</tr></thead><tbody>#{body}</tbody></table>"
    end

    private def self.error_detail(ops : Ops, fingerprint : String) : String
      entry = ops.errors.find(fingerprint) || return "<p>Nothing in this process matches " \
                                                     "#{HTML.escape(fingerprint)}. #{SINCE}</p>"
      report = entry.report.to_event(Detail::Development)
      frames = (report.backtrace || [] of String).join('\n')
      "<h2>#{HTML.escape(report.error_class)}</h2><p>#{entry.count} times, last " \
      "#{entry.last_seen.to_rfc3339}</p><pre>#{HTML.escape(report.message.to_s)}</pre>" \
      "<h2>Backtrace</h2><pre>#{HTML.escape(frames)}</pre><p>#{SINCE}</p>"
    end

    private def self.traces(ops : Ops) : String
      found = ops.traces.traces
      "#{Render.traces_table_html(found, "/traces/")}<p>Errors, slow requests and debug traces. " \
      "#{SINCE}</p>"
    end

    private def self.trace_detail(ops : Ops, ref : String) : String
      event = ops.traces.find(ref) || return "<p>Nothing in this process matches " \
                                             "#{HTML.escape(ref)}. #{SINCE}</p>"
      Render.trace_html(event, nil, nil)
    end
  end
end
