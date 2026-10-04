require "http/client"
require "json"
require "socket"
require "./ops"
require "./render"

module Caramel::Crema
  # `APP ops …`: the ops socket's command-line client. It speaks the same JSON API the
  # console does, over the Unix socket, so it works from the machine the app runs on.
  class OpsClient
    MISSING = "No ops socket at %s. Is the application running with CARAMEL_OPS_SOCKET?"
    FORWARD = 8765

    struct Options
      getter words = [] of String
      getter flags = Set(String).new
      getter values = {} of String => String

      def initialize(arguments : Array(String))
        arguments.each do |argument|
          next @words << argument unless argument.starts_with?("--")

          name, equals, value = argument.partition('=')
          equals.empty? ? @flags << name : (@values[name] = value)
        end
      end

      def flag?(name : String) : Bool
        @flags.includes?(name)
      end

      def []?(name : String) : String?
        @values[name]?
      end
    end

    def initialize(arguments : Array(String), @output : IO = STDOUT, @error : IO = STDERR)
      @options = Options.new(arguments)
      @path = @options["--socket"]? || Ops.path || ""
    end

    def run : Int32
      command = @options.words.first? || return usage
      return missing if @path.empty? || !File.exists?(@path)

      dispatch(command)
    rescue error : Socket::Error | File::Error
      @error.puts(error.is_a?(Socket::ConnectError) ? MISSING % @path : error.message)
      1
    end

    private def dispatch(command : String) : Int32
      case command
      when "status"      then status
      when "requests"    then requests
      when "fibers"      then fibers
      when "metrics"     then print_body(get("/v1/metrics"))
      when "tail"        then tail
      when "errors"      then errors
      when "error"       then error(argument)
      when "traces"      then traces
      when "trace"       then trace(argument)
      when "debug-token" then debug_token
      when "console"     then console
      else                    usage
      end
    end

    private def usage : Int32
      @error.puts("Usage: ops status|requests|fibers|metrics|tail|errors|error FINGERPRINT|" \
                  "traces|trace REF|debug-token|console [--socket=PATH]")
      2
    end

    private def missing : Int32
      @error.puts(MISSING % (@path.empty? ? "(unset)" : @path))
      1
    end

    private def argument : String
      @options.words[1]? || ""
    end

    private def connect : HTTP::Client
      HTTP::Client.new(UNIXSocket.new(@path), "ops")
    end

    private def get(path : String) : HTTP::Client::Response
      headers = HTTP::Headers{"Host" => "ops"}
      connect.get(path, headers)
    end

    private def json(path : String) : JSON::Any
      JSON.parse(get(path).body)
    end

    private def print_body(response : HTTP::Client::Response) : Int32
      @output.print(response.body)
      response.success? ? 0 : 1
    end

    # The response's JSON when it succeeded, nil after printing why not.
    private def answer(path : String) : JSON::Any?
      response = get(path)
      return JSON.parse(response.body) if response.success?

      message = JSON.parse(response.body)["error"]?.try(&.["message"]?).try(&.as_s?)
      @error.puts(message || "The ops socket answered #{response.status_code}")
      nil
    end

    private def status : Int32
      document = answer("/v1/status") || return 1
      return pretty(document) if @options.flag?("--json")

      active = answer("/v1/requests") || return 1
      groups = answer("/v1/fibers") || return 1
      @output.puts(StatusBlock.new(document, active, groups).to_s)
      0
    end

    private def pretty(document : JSON::Any) : Int32
      @output.puts(document.to_pretty_json)
      0
    end

    private def requests : Int32
      document = answer("/v1/requests") || return 1
      return pretty(document) if @options.flag?("--json")

      rows = document["active"].as_a.map do |item|
        [item["kind"].as_s, item["name"].as_s, item["request_id"]?.try(&.as_s?).to_s,
         Render.ms(item["elapsed_ms"].as_f), item["db_count"].to_s]
      end
      @output.puts(Table.new(%w[KIND NAME REQUEST_ID ELAPSED_MS QUERIES], rows).to_text)
      0
    end

    private def fibers : Int32
      document = answer("/v1/fibers") || return 1
      return pretty(document) if @options.flag?("--json")

      rows = document["groups"].as_a.map { |item| [item["name"].as_s, item["count"].to_s] }
      @output.puts("#{document["total"]} fibers")
      @output.puts(Table.new(%w[NAME COUNT], rows).to_text)
      0
    end

    private def errors : Int32
      document = answer("/v1/errors") || return 1
      return pretty(document) if @options.flag?("--json")

      rows = document["errors"].as_a.map do |item|
        [item["fingerprint"].as_s, item["count"].to_s, item["last_seen"].as_s[11, 8],
         item["error_class"].as_s, item["location"]?.try(&.as_s?).to_s,
         item["source"]?.try(&.as_s?).to_s]
      end
      @output.puts(Table.new(%w[FINGERPRINT COUNT LAST_SEEN CLASS LOCATION SOURCE], rows).to_text)
      0
    end

    private def error(fingerprint : String) : Int32
      response = get("/v1/errors/#{URI.encode_path_segment(fingerprint)}")
      return nothing(fingerprint) unless response.success?

      entry = JSON.parse(response.body)["error"]
      report = entry["report"]
      @output.puts("#{report["error_class"]} #{entry["fingerprint"]} (#{entry["count"]} times)")
      report["location"]?.try { |location| @output.puts("at #{location}") }
      @output.puts(report["message"]?.try(&.as_s?).to_s)
      report["backtrace"]?.try(&.as_a.each { |frame| @output.puts("  #{frame}") })
      0
    end

    private def nothing(reference : String) : Int32
      @error.puts("Nothing in this process matches #{reference}; restarts clear the rings.")
      1
    end

    private def traces : Int32
      reason = {"--errors" => "error", "--slow" => "slow", "--debug" => "debug"}
        .find { |flag, _| @options.flag?(flag) }.try(&.[1])
      limit = @options["--limit"]?.try(&.to_i?) || 50
      query = String.build do |io|
        io << "/v1/traces?limit=" << limit
        io << "&reason=" << reason if reason
      end
      document = answer(query) || return 1
      return pretty(document) if @options.flag?("--json")

      document["traces"].as_a.each do |item|
        @output.puts(trace_line(TraceEvent.from_json(item.to_json)))
      end
      0
    end

    private def trace_line(event : TraceEvent) : String
      stamp = Time.parse_rfc3339(event.started_at).to_local.to_s("%H:%M:%S")
      "#{stamp} #{(event.reason || "").ljust(5)} #{Render.line(event)}"
    end

    private def trace(reference : String) : Int32
      response = get("/v1/traces/#{URI.encode_path_segment(reference)}")
      return nothing(reference) unless response.success?

      event = TraceEvent.from_json(JSON.parse(response.body)["trace"].to_json)
      @output.puts(@options.flag?("--md") ? Render.markdown(event) : Render.detail(event))
      0
    end

    private def tail : Int32
      query = String.build do |io|
        io << "/v1/tail?logs=" << (@options.flag?("--logs") ? 1 : 0)
        io << "&errors=1" if @options.flag?("--errors")
        @options["--slow"]?.try { |limit| io << "&slow=" << limit }
      end
      connect.get(query, HTTP::Headers{"Host" => "ops"}) do |response|
        response.body_io.each_line { |line| show_event(line) }
      end
      0
    end

    private def show_event(line : String) : Nil
      return unless line.starts_with?("data: ")

      data = line.lchop("data: ")
      return @output.puts(data) if @options.flag?("--json")

      event = JSON.parse(data)
      stamp = Time.local.to_s("%H:%M:%S")
      @output.puts("#{stamp} #{tail_text(event, data)}")
    end

    private def tail_text(event : JSON::Any, data : String) : String
      case event["type"]?.try(&.as_s?)
      when "trace" then Render.line(TraceEvent.from_json(data))
      when "error" then Render.line(ErrorEvent.from_json(data))
      else              "#{event["level"]?} #{event["source"]?}: #{event["message"]?}"
      end
    end

    private def debug_token : Int32
      minutes = @options["--minutes"]?.try(&.to_i?) || Ops::DEFAULT_MINUTES
      headers = HTTP::Headers{"Host" => "ops", "Content-Type" => "application/json"}
      response = connect.post("/v1/debug-tokens", headers, {minutes: minutes}.to_json)
      return failure(response) unless response.success?

      document = JSON.parse(response.body)
      token = document["token"].as_s
      expires = Time.parse_rfc3339(document["expires_at"].as_s).to_utc.to_s("%Y-%m-%d %H:%M UTC")
      @output.puts <<-TEXT
        Token    #{token}
        Expires  #{expires}
        curl     curl -H 'X-Caramel-Debug: #{token}' https://<host>/path
        Browser  document.cookie = "__Host-caramel_debug=#{token}; Path=/; Secure; SameSite=Strict"
        TEXT
      0
    end

    private def failure(response : HTTP::Client::Response) : Int32
      message = JSON.parse(response.body)["error"]?.try(&.["message"]?).try(&.as_s?)
      @error.puts(message || "The ops socket answered #{response.status_code}")
      1
    end

    private def console : Int32
      path = File.expand_path(@path)
      @output.puts("ssh -N -L #{FORWARD}:#{path} #{System.hostname}")
      @output.puts("then open http://localhost:#{FORWARD}/")
      0
    end
  end

  # The block `ops status` prints.
  struct StatusBlock
    def initialize(@status : JSON::Any, @active : JSON::Any, @groups : JSON::Any)
    end

    def to_s(io : IO) : Nil
      io << "App       " << app << '\n'
      io << "Requests  " << requests << '\n'
      io << "Jobs      " << jobs << '\n'
      io << "Database  " << database << '\n'
      io << "Memory    " << memory << '\n'
      io << "Fibers    " << fibers << '\n'
      io << "Crema     " << crema
    end

    private def app : String
      "#{@status["app"]} · caramel #{@status["caramel"]} · #{@status["role"]} · " \
      "pid #{@status["pid"]} · up #{uptime(@status["uptime_s"].as_i64)}"
    end

    private def uptime(seconds : Int64) : String
      return "#{seconds}s" if seconds < 60
      return "#{seconds // 60}m" if seconds < 3600

      "#{seconds // 3600}h#{(seconds % 3600) // 60}m"
    end

    private def requests : String
      figures = @status["requests"]
      "#{@status["inflight"]} in flight · #{figures["total"]} since start · " \
      "#{figures["errors"]} errors · p95 #{figures["p95_ms"].as_f.round.to_i}ms"
    end

    private def jobs : String
      running = @active["active"].as_a.count { |item| item["kind"] == "job" }
      workers = @status["workers"].as_a
      queues = workers.join(", ") { |worker| "#{worker["queue"]}×#{worker["concurrency"]}" }
      "#{queues.presence || "none"} · #{running} running · scheduler #{@status["scheduler"]}"
    end

    private def database : String
      pools = @status["pools"].as_a
      return "none" if pools.empty?

      pools.join(" · ") do |pool|
        "#{pool["name"]} #{pool["open"]}/#{pool["max"]} open, #{pool["in_flight"]} in use"
      end
    end

    private def memory : String
      gc = @status["gc"]
      "heap #{megabytes(gc["heap_bytes"])} · free #{megabytes(gc["free_bytes"])} · " \
      "allocated #{megabytes(gc["total_bytes"])}"
    end

    private def megabytes(value : JSON::Any) : String
      bytes = value.as_i64.to_f
      bytes >= 1e9 ? "%.1f GB" % (bytes / 1e9) : "%.1f MB" % (bytes / 1e6)
    end

    private def fibers : String
      groups = @groups["groups"].as_a.sort_by { |group| -group["count"].as_i }
      shown = groups.first(3).join(", ") { |group| "#{group["name"]} #{group["count"]}" }
      more = groups.size > 3 ? ", …" : ""
      "#{@groups["total"]} (#{shown}#{more})"
    end

    private def crema : String
      sinks = @status["sinks"].as_a.join(", ")
      dropped = @status["dropped"].as_h.values.sum(&.as_i64)
      "sinks #{sinks} · dropped #{dropped}"
    end
  end
end
