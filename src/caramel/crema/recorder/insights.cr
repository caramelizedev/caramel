require "../../command_line"
require "../console"
require "../table"
require "../tally"

module Caramel::Crema
  # `APP insights` and the console's Insights page: the recorder's rows, summed over
  # a window, with latency percentiles from the summed histograms.
  module Insights
    KINDS   = %w[request job schedule sql outbound]
    HEADERS = %w[KEY COUNT ERR P50MS P95MS MAXMS TOTAL_S]
    LIMIT   = 20
    USAGE   = "insights [--since=DURATION] [--kind=request|job|schedule|sql|outbound]"

    QUERY = <<-SQL
      SELECT metrics.key AS key,
        sum(metrics.count)::bigint AS count,
        sum(metrics.errors)::bigint AS errors,
        sum(metrics.total_ms)::float8 AS total_ms,
        max(metrics.max_ms)::float8 AS max_ms,
        ARRAY(
          SELECT sum(h.n)::bigint
          FROM caramel_metrics inner_rows,
            unnest(inner_rows.histogram) WITH ORDINALITY AS h(n, i)
          WHERE inner_rows.kind = metrics.kind AND inner_rows.key = metrics.key
            AND inner_rows.bucket >= now() - make_interval(secs => $2)
          GROUP BY h.i
          ORDER BY h.i
        ) AS histogram
      FROM caramel_metrics metrics
      WHERE metrics.kind = $1 AND metrics.bucket >= now() - make_interval(secs => $2)
      GROUP BY metrics.kind, metrics.key
      ORDER BY sum(metrics.total_ms) DESC
      LIMIT #{LIMIT}
      SQL

    ROW = {
      key: String, count: Int64, errors: Int64, total_ms: Float64, max_ms: Float64,
      histogram: Array(Int64),
    }

    # `<int>m`, `<int>h` or `<int>d` as a span; nil for anything else.
    def self.duration(text : String) : Time::Span?
      match = /\A(\d+)([mhd])\z/.match(text) || return
      amount = match[1].to_i
      case match[2]
      when "m" then amount.minutes
      when "h" then amount.hours
      else          amount.days
      end
    end

    # The table for one *kind* over *since*, busiest by total time first.
    def self.table(kind : String, since : Time::Span, db : DB::Database? = nil) : Table
      rows = SugarORM::Repo.using(db || SugarORM::Repo.database) do
        SugarORM.sql(QUERY, kind, since.total_seconds, as: ROW)
      end
      Table.new(HEADERS, rows.map { |row| cells(row) })
    end

    private def self.cells(row) : Array(String)
      histogram = Histogram.new(row[:histogram])
      max = row[:max_ms]
      [row[:key], row[:count].to_s, row[:errors].to_s,
       Render.ms(Math.min(histogram.quantile(0.5, max), max)),
       Render.ms(Math.min(histogram.quantile(0.95, max), max)),
       Render.ms(max), (row[:total_ms] / 1000.0).round(1).to_s]
    end

    def self.run(arguments : Array(String), db : DB::Database) : Int32
      since_text = arguments.find(&.starts_with?("--since=")).try(&.lchop("--since=")) || "1h"
      kind = arguments.find(&.starts_with?("--kind=")).try(&.lchop("--kind=")) || "request"
      since = duration(since_text)
      unless since && KINDS.includes?(kind)
        STDERR.puts("Usage: #{USAGE}")
        return 2
      end
      found = table(kind, since, db)
      empty = "No aggregates in the last #{since_text}. Is the recorder running?"
      puts(found.empty? ? empty : found.to_text)
      0
    end

    # One table per kind for the console, from the request's `?since=`.
    def self.page(request : HTTP::Request, db : DB::Database?) : String
      return "<p>This process has no database.</p>" unless db

      text = request.query_params["since"]? || "1h"
      since = duration(text) || 1.hour
      KINDS.join do |kind|
        "<h2>#{HTML.escape(kind.capitalize)}</h2>#{table(kind, since, db).to_html}"
      end
    end
  end

  command("insights", Insights::USAGE) do |arguments|
    CommandLine.with_database(false) { |db, _| Insights.run(arguments, db) }
  end

  console_page("insights") do |request|
    Insights.page(request, Crema.runtime?.try(&.database))
  end
end
