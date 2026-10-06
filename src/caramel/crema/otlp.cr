require "http/client"
require "uri"
require "./otlp_json"
require "./runtime"

module Caramel::Crema
  # The opt-in OTLP/HTTP trace exporter (ADR 0028): `require "caramel/crema/otlp"`, then
  # set `OTEL_EXPORTER_OTLP_ENDPOINT`. It sends sampled traces as OTLP JSON to any
  # collector or vendor that accepts it, and nothing at all without an endpoint.
  module Otlp
    # Decides once per trace whether its spans are exported.
    struct Sampler
      KINDS = %w[always_on always_off traceidratio parentbased_always_on
        parentbased_always_off parentbased_traceidratio]

      def initialize(@kind : String, @ratio : Float64)
      end

      # An unknown sampler name warns and falls back to `traceidratio`.
      def self.from(env) : Sampler
        ratio = env["OTEL_TRACES_SAMPLER_ARG"]?.try(&.to_f?) || 1.0
        kind = env["OTEL_TRACES_SAMPLER"]?.presence || "traceidratio"
        unless KINDS.includes?(kind)
          LOG.warn { "unknown OTEL_TRACES_SAMPLER #{kind.inspect}; using traceidratio" }
          kind = "traceidratio"
        end
        new(kind, ratio.clamp(0.0, 1.0))
      end

      def sample?(trace : Trace) : Bool
        return true if trace.debug?

        case @kind
        when "always_on"  then true
        when "always_off" then false
        when "parentbased_always_on"
          trace.parent_sampled.nil? ? true : trace.parent_sampled == true
        when "parentbased_always_off"
          trace.parent_sampled == true
        when "parentbased_traceidratio"
          parent = trace.parent_sampled
          parent.nil? ? ratio?(trace.trace_id) : parent
        else ratio?(trace.trace_id)
        end
      end

      # True when the first 16 hex digits of *trace_id* fall under the ratio.
      private def ratio?(trace_id : String) : Bool
        return true if @ratio >= 1.0

        trace_id[0, 16].to_u64(16) < (@ratio * UInt64::MAX)
      end
    end

    # Sends finished traces to the collector on a fiber of its own.
    class Exporter < Sink
      CAPACITY    = 2048
      BATCH_SPANS =  512
      INTERVAL    = 5.seconds
      LOG_EVERY   = 1.minute

      def initialize(@endpoint : URI,
                     @headers : HTTP::Headers,
                     @service : String,
                     @environment : String,
                     @sampler : Sampler)
        @queue = Channel(TraceEvent).new(CAPACITY)
        @done = Channel(Nil).new
        @logged = Time.instant - LOG_EVERY
      end

      def name : String
        "otlp"
      end

      # Records spans only for a trace that will be exported.
      def records?(trace : Trace) : Bool
        trace.sampled = @sampler.sample?(trace)
        trace.sampled?
      end

      def finished(trace : Trace) : Nil
        return unless trace.sampled? || trace.outcome == "error"

        event = trace.to_event(Detail::Production)
        event.spans = [] of SpanEvent unless trace.sampled?
        select
        when @queue.send(event)
        else
          Crema.drop("otlp")
        end
      end

      def start : self
        spawn(name: "crema:otlp") { run }
        self
      end

      def stop : Nil
        @queue.close
        @done.receive?
      end

      private def run : Nil
        batch = [] of TraceEvent
        spans = 0
        deadline = Time.instant + INTERVAL
        loop do
          select
          when event = @queue.receive?
            break send(batch) unless event

            batch << event
            spans += 1 + event.spans.size
            next if spans < BATCH_SPANS

            send(batch)
            batch, spans, deadline = [] of TraceEvent, 0, Time.instant + INTERVAL
          when timeout({deadline - Time.instant, Time::Span.zero}.max)
            send(batch)
            batch, spans, deadline = [] of TraceEvent, 0, Time.instant + INTERVAL
          end
        end
      ensure
        @done.close
      end

      # Posts *batch*. A refusal or an error drops it and is logged at most once a minute.
      private def send(batch : Array(TraceEvent)) : Nil
        return if batch.empty?

        body = OtlpJson.encode(batch, @service, @environment)
        response = post(body)
        return if response.success?

        failed(batch.size, "status=#{response.status_code}")
      rescue error
        failed(batch.size, "error_type=#{error.class}")
      end

      private def post(body : String) : HTTP::Client::Response
        client = HTTP::Client.new(@endpoint)
        client.connect_timeout = 5.seconds
        client.read_timeout = 10.seconds
        begin
          headers = @headers.dup
          headers["Content-Type"] = "application/json"
          client.post(@endpoint.request_target, headers, body)
        ensure
          client.close
        end
      end

      private def failed(count : Int32, detail : String) : Nil
        Crema.drop("otlp", count.to_i64)
        return if Time.instant - @logged < LOG_EVERY

        @logged = Time.instant
        LOG.warn { "otlp export failed #{detail}" }
      end
    end

    # The endpoint the environment names, or nil.
    def self.endpoint(env) : URI?
      traces = env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"]?.presence
      base = env["OTEL_EXPORTER_OTLP_ENDPOINT"]?.presence
      text = traces || base.try { |url| "#{url.rstrip('/')}/v1/traces" } || return
      URI.parse(text)
    end

    # `k=v` pairs separated by commas, each side percent-decoded.
    def self.headers(env) : HTTP::Headers
      headers = HTTP::Headers.new
      env["OTEL_EXPORTER_OTLP_HEADERS"]?.try(&.split(',')).try do |pairs|
        pairs.each do |pair|
          name, _, value = pair.partition('=')
          headers[URI.decode(name.strip)] = URI.decode(value.strip) unless name.strip.empty?
        end
      end
      headers
    end

    # Starts the exporter for *runtime* when the environment asks for one; returns what
    # stops it (after a last flush), or nil when export is off.
    def self.activate(runtime : Runtime, env = ENV) : Stopper?
      endpoint = endpoint(env) || return
      protocol = env["OTEL_EXPORTER_OTLP_PROTOCOL"]?
      if protocol && protocol != "http/json"
        LOG.warn { "OTLP export needs OTEL_EXPORTER_OTLP_PROTOCOL=http/json; export is off" }
        return
      end
      service = env["OTEL_SERVICE_NAME"]?.presence || runtime.app
      environment = env["CARAMEL_ENV"]? || "production"
      exporter = Exporter.new(endpoint, headers(env), service, environment, Sampler.from(env)).start
      Crema.subscribe(exporter)
      -> do
        Crema.unsubscribe(exporter)
        exporter.stop
        nil
      end
    end
  end

  on_start { |runtime| Otlp.activate(runtime) }
end
