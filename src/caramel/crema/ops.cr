require "http/server"
require "json"
require "socket"
require "../version"
require "./debug_token"
require "./prometheus"
require "./rings"
require "./runtime"

module Caramel::Crema
  # The ops socket (ADR 0028): an HTTP/1.1 API and a read-only console on an
  # owner-only Unix socket inside the running binary. Nothing here listens on
  # the public listener. Every request must name a local host, and a write
  # that carries an `Origin` header is refused, so a web page cannot reach it.
  class Ops
    include HTTP::Handler

    HOSTS           = {"ops", "localhost", "127.0.0.1", "[::1]"}
    JSON_TYPE       = "application/json"
    DEFAULT_MINUTES =  15
    MAX_MINUTES     = 120
    PING            = 15.seconds
    MAX_BODY        = 1024
    MAX_TAILS       =    8
    IO_TIMEOUT      = 10.seconds

    alias Route = Proc(HTTP::Server::Context, Nil)

    getter runtime : Runtime
    getter errors : ErrorRing
    getter traces : TraceRing
    @routes : Hash(String, Route)? = nil
    @tails = Atomic(Int32).new(0)
    @stopping = Channel(Nil).new

    # The socket path `CARAMEL_OPS_SOCKET` and `CARAMEL_SOCKET` ask for, or nil for none:
    # `off` disables it, and without either the process has no ops socket.
    def self.path(env = ENV) : String?
      explicit = env["CARAMEL_OPS_SOCKET"]?
      return if explicit == "off"
      return explicit if explicit && !explicit.empty?

      socket = env["CARAMEL_SOCKET"]? || return
      File.join(File.dirname(socket), "#{File.basename(socket, ".sock")}.ops.sock")
    end

    # Where *runtime* serves: its derived path for `serve`, only an explicit
    # `CARAMEL_OPS_SOCKET` for `work`.
    def self.path_for(runtime : Runtime, env = ENV) : String?
      return path(env) if runtime.role == "serve"

      env["CARAMEL_OPS_SOCKET"]?.presence.try { |explicit| explicit == "off" ? nil : explicit }
    end

    def initialize(@runtime : Runtime,
                   @errors : ErrorRing = ErrorRing.new,
                   @traces : TraceRing = TraceRing.new)
    end

    def call(context : HTTP::Server::Context) : Nil
      request = context.request
      return refuse(context, 421, "misdirected", "Unknown host") unless local_host?(request)
      if request.method != "GET" && request.headers.has_key?("Origin")
        return refuse(context, 403, "forbidden", "Browsers may not write to the ops socket")
      end

      table = @routes ||= routes
      handler = table["#{request.method} #{request.path}"]? || prefixed(request)
      return handler.call(context) if handler

      missing(context)
    end

    private def local_host?(request : HTTP::Request) : Bool
      host = request.headers["Host"]? || return false
      HOSTS.includes?(host.sub(/:\d+\z/, ""))
    end

    private def routes : Hash(String, Route)
      api = {
        "GET /v1/status"        => ->(context : HTTP::Server::Context) { status(context) },
        "GET /v1/requests"      => ->(context : HTTP::Server::Context) { requests(context) },
        "GET /v1/fibers"        => ->(context : HTTP::Server::Context) { fibers(context) },
        "GET /v1/metrics"       => ->(context : HTTP::Server::Context) { metrics(context) },
        "GET /v1/tail"          => ->(context : HTTP::Server::Context) { tail(context) },
        "GET /v1/errors"        => ->(context : HTTP::Server::Context) { error_list(context) },
        "GET /v1/traces"        => ->(context : HTTP::Server::Context) { trace_list(context) },
        "POST /v1/debug-tokens" => ->(context : HTTP::Server::Context) { debug_token(context) },
      }
      api.merge(Console.routes(self))
    end

    private def prefixed(request : HTTP::Request) : Route?
      return unless request.method == "GET"

      path = request.path
      if path.starts_with?("/v1/errors/")
        ->(context : HTTP::Server::Context) { error_detail(context, path.lchop("/v1/errors/")) }
      elsif path.starts_with?("/v1/traces/")
        ->(context : HTTP::Server::Context) { trace_detail(context, path.lchop("/v1/traces/")) }
      else
        Console.prefixed(self, path)
      end
    end

    # A JSON answer: the API version, then what the block writes.
    def json(context : HTTP::Server::Context, status : Int32 = 200, & : JSON::Builder ->) : Nil
      body = JSON.build do |builder|
        builder.object do
          builder.field "version", 1
          yield builder
        end
      end
      respond(context, status, JSON_TYPE, body)
    end

    # Answers are never cached or sniffed.
    def respond(context : HTTP::Server::Context, status : Int32, type : String, body : String) : Nil
      response = context.response
      response.status_code = status
      response.content_type = type
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.print(body)
    end

    def refuse(context : HTTP::Server::Context,
               status : Int32,
               code : String,
               message : String) : Nil
      json(context, status) do |builder|
        builder.field "error" do
          builder.object do
            builder.field "code", code
            builder.field "message", message
          end
        end
      end
    end

    private def missing(context : HTTP::Server::Context) : Nil
      path = context.request.path
      return refuse(context, 404, "not_found", "Nothing at #{path}") if path.starts_with?("/v1/")

      Console.not_found(self, context)
    end

    private def status(context : HTTP::Server::Context) : Nil
      json(context) { |builder| Status.write(builder, @runtime) }
    end

    private def requests(context : HTTP::Server::Context) : Nil
      json(context) do |builder|
        builder.field "active" do
          builder.array { Crema.in_flight.each { |trace| active(builder, trace) } }
        end
      end
    end

    private def active(builder : JSON::Builder, trace : Trace) : Nil
      builder.object do
        builder.field "kind", trace.kind.wire
        builder.field "name", trace.name
        builder.field "request_id", trace.request_id
        builder.field "trace_id", trace.trace_id
        builder.field "started_at", trace.started_at.to_rfc3339(fraction_digits: 3)
        builder.field "elapsed_ms", Trace.ms(trace.elapsed)
        builder.field "db_count", trace.db_count
      end
    end

    private def fibers(context : HTTP::Server::Context) : Nil
      groups = Crema.fiber_groups
      json(context) do |builder|
        builder.field "total", groups.values.sum
        builder.field "groups" do
          builder.array do
            groups.each do |name, count|
              builder.object do
                builder.field "name", name
                builder.field "count", count
              end
            end
          end
        end
      end
    end

    private def metrics(context : HTTP::Server::Context) : Nil
      body = String.build { |io| Prometheus.write(io, Crema.metrics, @runtime) }
      respond(context, 200, Prometheus::CONTENT_TYPE, body)
    end

    private def tail(context : HTTP::Server::Context) : Nil
      return refuse(context, 429, "too_many_tails", "At most #{MAX_TAILS} tails") if tail_full?
      params = context.request.query_params
      filter = TailSink::Filter.new(
        errors: params["errors"]? == "1",
        slow_ms: params["slow"]?.try(&.to_f?),
        logs: params["logs"]? == "1")
      subscriber = Crema.tail.subscribe(filter)
      response = context.response
      response.content_type = "text/event-stream"
      response.headers["Cache-Control"] = "no-store"
      response.print(": ok\n\n")
      response.flush
      stream(response, subscriber)
    rescue IO::Error | HTTP::Server::ClientError
      nil
    ensure
      subscriber.try { |open| Crema.tail.unsubscribe(open) }
      @tails.sub(1)
    end

    # Counts this tail in; true when `MAX_TAILS` others are already open.
    private def tail_full? : Bool
      @tails.add(1) >= MAX_TAILS
    end

    # Ends every open tail so its handler returns.
    def stop_tails : Nil
      @stopping.close unless @stopping.closed?
    end

    private def stream(response : HTTP::Server::Response, subscriber : TailSink::Subscriber) : Nil
      loop do
        select
        when line = subscriber.channel.receive
          response.print("data: ", line, "\n\n")
        when @stopping.receive?
          return
        when timeout(PING)
          response.print(": ping\n\n")
        end
        response.flush
      end
    end

    private def error_list(context : HTTP::Server::Context) : Nil
      json(context) do |builder|
        builder.field "errors" do
          builder.array { @errors.entries.each { |entry| error_summary(builder, entry) } }
        end
      end
    end

    private def error_summary(builder : JSON::Builder, entry : ErrorRing::Entry) : Nil
      builder.object do
        error_fields(builder, entry)
        builder.field "error_class", entry.report.error_class
        builder.field "location", entry.report.location
        builder.field "source", entry.report.source
      end
    end

    private def error_fields(builder : JSON::Builder, entry : ErrorRing::Entry) : Nil
      builder.field "fingerprint", entry.fingerprint
      builder.field "count", entry.count
      builder.field "first_seen", entry.first_seen.to_rfc3339(fraction_digits: 3)
      builder.field "last_seen", entry.last_seen.to_rfc3339(fraction_digits: 3)
    end

    # The one answer that carries an exception's redacted message and backtrace.
    private def error_detail(context : HTTP::Server::Context, fingerprint : String) : Nil
      entry = @errors.find(fingerprint) || return refuse(context, 404, "not_found", "No such error")
      json(context) do |builder|
        builder.field "error" do
          builder.object do
            error_fields(builder, entry)
            builder.field "error_class", entry.report.error_class
            builder.field "report" do
              entry.report.to_event(Detail::Development).to_json(builder)
            end
          end
        end
      end
    end

    private def trace_list(context : HTTP::Server::Context) : Nil
      params = context.request.query_params
      limit = (params["limit"]?.try(&.to_i?) || 50).clamp(1, TraceRing::CAPACITY)
      found = @traces.traces(params["reason"]?, limit)
      json(context) do |builder|
        builder.field "traces" do
          builder.array { found.each(&.to_json(builder)) }
        end
      end
    end

    private def trace_detail(context : HTTP::Server::Context, ref : String) : Nil
      event = @traces.find(ref) || return refuse(context, 404, "not_found", "No such trace")
      json(context) do |builder|
        builder.field "trace" do
          event.to_json(builder)
        end
      end
    end

    private def debug_token(context : HTTP::Server::Context) : Nil
      key = Crema.debug_key || return refuse(context, 404, "not_found", "No application here")
      type = context.request.headers["Content-Type"]?
      unless type && type.starts_with?(JSON_TYPE)
        return refuse(context, 415, "unsupported_media_type", "Send application/json")
      end
      body = request_body(context.request)
      return refuse(context, 413, "request_too_large", "Body is limited to 1 KiB") unless body

      minutes = requested_minutes(body)
      return refuse(context, 400, "bad_request", "minutes must be 1 to 120") unless minutes

      token, expires = DebugToken.issue(key, minutes)
      json(context) do |builder|
        builder.field "token", token
        builder.field "expires_at", expires.to_rfc3339
      end
    end

    # The body, or nil when it is longer than `MAX_BODY` bytes.
    private def request_body(request : HTTP::Request) : String?
      source = request.body || return ""
      text = IO::Sized.new(source, MAX_BODY + 1).gets_to_end
      text.bytesize > MAX_BODY ? nil : text
    end

    private def requested_minutes(body : String) : Int32?
      return DEFAULT_MINUTES if body.blank?

      value = JSON.parse(body).as_h?.try(&.["minutes"]?) || return DEFAULT_MINUTES
      minutes = value.as_i? || return
      (1..MAX_MINUTES).includes?(minutes) ? minutes : nil
    rescue JSON::ParseException
      nil
    end

    # Starts the ops socket for *runtime* and returns what stops it, or nil when
    # this process has none. Trouble with the socket is logged; it never stops the app.
    def self.start(runtime : Runtime, env = ENV) : Stopper?
      path = path_for(runtime, env) || return
      directory = File.dirname(path)
      unless Crema.private_directory?(directory)
        LOG.warn { "ops socket disabled: #{directory} is not a private directory you own" }
        return
      end
      return unless free?(path)

      ops = new(runtime)
      server = HTTP::Server.new([ops])
      server.bind(TimedServer.new(path))
      File.chmod(path, 0o600)
      Crema.subscribe(ops.errors)
      Crema.subscribe(ops.traces)
      spawn(name: "crema:ops") do
        server.listen unless server.closed?
      rescue error
        LOG.warn { "ops socket stopped error_type=#{error.class}" } unless server.closed?
      end
      -> do
        Crema.unsubscribe(ops.errors)
        Crema.unsubscribe(ops.traces)
        ops.stop_tails
        server.close unless server.closed?
        File.delete?(path)
        nil
      end
    rescue error : IO::Error | Socket::Error | File::Error
      LOG.warn { "ops socket disabled error_type=#{error.class}" }
      nil
    end

    # A listener whose connections time out, so a stalled client cannot hold a fiber.
    class TimedServer < UNIXServer
      def accept? : UNIXSocket?
        super.try do |client|
          client.read_timeout = IO_TIMEOUT
          client.write_timeout = IO_TIMEOUT
          client
        end
      end
    end

    # True when nothing answers on *path*; a socket left by a crash is removed.
    # Anything that is not a socket of ours is left alone.
    private def self.free?(path : String) : Bool
      info = File.info?(path, follow_symlinks: false) || return true
      unless info.type.socket? && info.owner_id == LibC.getuid.to_s
        LOG.warn { "ops socket disabled: #{path} exists and is not a socket" }
        return false
      end

      socket = Socket.unix
      begin
        socket.connect(Socket::UNIXAddress.new(path), timeout: 200.milliseconds)
        LOG.warn { "ops socket is already in use: #{path}" }
        false
      rescue error : Socket::ConnectError
        raise error unless {Errno::ECONNREFUSED, Errno::ENOENT}.includes?(error.os_error)
        File.delete?(path)
        true
      ensure
        socket.close
      end
    end
  end

  # The `/v1/status` document.
  module Status
    def self.write(builder : JSON::Builder, runtime : Runtime) : Nil
      builder.field "app", runtime.app
      builder.field "caramel", Caramel::VERSION
      builder.field "role", runtime.role
      builder.field "pid", Process.pid
      builder.field "started_at", runtime.started_at.to_rfc3339(fraction_digits: 3)
      builder.field "uptime_s", (Time.utc - runtime.started_at).total_seconds.to_i64
      builder.field "environment", ENV["CARAMEL_ENV"]? || "production"
      builder.field "inflight", Crema.in_flight.size
      builder.field "fibers", Crema.fiber_count
      requests(builder)
      memory(builder)
      pools(builder, runtime)
      jobs(builder, runtime)
      builder.field "sinks", Crema.sinks.map(&.name)
      builder.field "dropped", Crema.dropped
    end

    private def self.requests(builder : JSON::Builder) : Nil
      total, errors, p95 = Crema.metrics.request_summary
      builder.field "requests" do
        builder.object do
          builder.field "total", total
          builder.field "errors", errors
          builder.field "p95_ms", p95.round(1)
        end
      end
    end

    private def self.memory(builder : JSON::Builder) : Nil
      stats = GC.stats
      builder.field "gc" do
        builder.object do
          builder.field "heap_bytes", stats.heap_size
          builder.field "free_bytes", stats.free_bytes
          builder.field "total_bytes", stats.total_bytes
        end
      end
    end

    private def self.pools(builder : JSON::Builder, runtime : Runtime) : Nil
      builder.field "pools" do
        builder.array do
          runtime.pools.each do |pool|
            builder.object do
              builder.field "name", pool.name
              builder.field "open", pool.open
              builder.field "idle", pool.idle
              builder.field "in_flight", pool.in_flight
              builder.field "max", pool.max
            end
          end
        end
      end
    end

    private def self.jobs(builder : JSON::Builder, runtime : Runtime) : Nil
      service = runtime.cold_brew
      builder.field "workers" do
        builder.array do
          service.try(&.workers.each do |worker|
            builder.object do
              builder.field "queue", worker.queue
              builder.field "concurrency", worker.concurrency
            end
          end)
        end
      end
      builder.field "scheduler", service && service.scheduler_on? ? "on" : "off"
    end
  end
end

require "./console"
