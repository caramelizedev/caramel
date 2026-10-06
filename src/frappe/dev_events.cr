require "http/client"
require "socket"
require "../caramel/crema/otlp_json"
require "./event_store"
require "./site_log"

module Caramel::Frappe
  # The development session's event store (ADR 0027). The application, started
  # with `CARAMEL_DEV_EVENTS` naming this socket, writes one JSON event per
  # line; they are kept in memory for the inspector and appended to the site's
  # `events.jsonl`, which `frappe traces` reads without a session.
  class DevEvents
    MAX_LINE  = 1_048_576
    LOG_BYTES = 8 * 1024 * 1024
    # How many traces wait for the collector before newer ones are dropped.
    FORWARD_QUEUE = 500
    UNAVAILABLE   = "Latte's trace collector is unavailable; cross-site traces are off."

    getter socket : String
    # How many errors the application reported since this session started; history
    # replayed from earlier sessions is not counted.
    getter errors_seen : Int32 = 0
    # The newest of them.
    getter last_error : Crema::ErrorEvent? = nil
    @server : UNIXServer? = nil
    @forward : Channel(Crema::TraceEvent)? = nil

    def initialize(directory : String, log_directory : String, @warnings : IO = STDERR)
      @socket = File.join(directory, "events-#{Random::Secure.hex(4)}.sock")
      @store = EventStore.new
      @store_lock = Mutex.new
      @store.replay(log_directory)
      @log = SiteLog.new(File.join(log_directory, EventStore::LOG_NAME), @warnings, LOG_BYTES)
    end

    # Starts listening on a private socket.
    def start : Nil
      server = UNIXServer.new(@socket)
      File.chmod(@socket, 0o600)
      @server = server
      spawn(name: "frappe:events") { accept(server) }
    end

    def build(event : Crema::BuildEvent) : Nil
      @store.add(event)
      append(event.to_json)
    end

    def latest : Int64
      @store.latest
    end

    def traces(after : Int64 = 0, limit : Int32 = 50) : Array({Int64, Crema::TraceEvent})
      @store.traces(after, limit)
    end

    def find(ref : String) : Crema::TraceEvent?
      @store.find(ref)
    end

    def for_request(id : String) : Crema::TraceEvent?
      @store.for_request(id)
    end

    def errors : Array(Crema::ErrorEvent)
      @store.errors
    end

    def builds : Array(Crema::BuildEvent)
      @store.builds
    end

    # Sends every trace the application reports to Latte's collector at *port*, as OTLP/HTTP
    # JSON for *service* (ADR 0029), from a fiber with a queue of 500; a full queue drops
    # the trace. A failed delivery is announced once.
    def forward(port : Int32, service : String) : Nil
      queue = Channel(Crema::TraceEvent).new(FORWARD_QUEUE)
      @forward = queue
      spawn(name: "frappe:otlp") { deliver(queue, port, service) }
    end

    def close : Nil
      @server.try(&.close)
      @forward.try(&.close)
      File.delete?(@socket)
      @log.close
    end

    private def accept(server : UNIXServer) : Nil
      while client = server.accept?
        spawn(name: "frappe:events:connection") { read(client) }
      end
    rescue IO::Error
      nil
    end

    private def read(client : UNIXSocket) : Nil
      while line = next_line(client)
        event = @store.ingest(line) || next
        note_error(event)
        queue_forward(event)
        append(line) if event.is_a?(Crema::TraceEvent | Crema::ErrorEvent)
      end
    rescue IO::Error
      nil
    ensure
      client.close
    end

    private def note_error(event : EventStore::Event) : Nil
      error = case event
              in Crema::TraceEvent then event.error
              in Crema::ErrorEvent then event
              in Crema::BuildEvent then nil
              end
      return unless error

      @errors_seen += 1
      @last_error = error
    end

    private def queue_forward(event : EventStore::Event) : Nil
      queue = @forward
      return unless queue && event.is_a?(Crema::TraceEvent)

      select
      when queue.send(event)
      else
        nil
      end
    rescue Channel::ClosedError
      nil
    end

    private def deliver(queue : Channel(Crema::TraceEvent), port : Int32, service : String) : Nil
      client = HTTP::Client.new("127.0.0.1", port)
      client.connect_timeout = 1.second
      client.read_timeout = 2.seconds
      client.write_timeout = 2.seconds
      announced = false
      while event = queue.receive?
        if delivered?(client, event, service)
          announced = false
        else
          @warnings.puts(UNAVAILABLE) unless announced
          announced = true
        end
      end
    ensure
      client.try(&.close)
    end

    # Whether Latte's collector accepted *event*. Any failure, including one encoding
    # the event, counts as a failed delivery and never ends the forwarding fiber.
    private def delivered?(
      client : HTTP::Client,
      event : Crema::TraceEvent,
      service : String,
    ) : Bool
      body = Crema::OtlpJson.encode([event], service: service, environment: "development")
      post(client, body)
    rescue
      false
    end

    # Whether Latte's collector accepted *body*.
    private def post(client : HTTP::Client, body : String) : Bool
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      client.post("/v1/traces", headers, body).success?
    rescue IO::Error | Socket::Error
      # The collector closes a connection after its answer; the next call reconnects.
      client.close
      false
    end

    # The next complete line, skipping any that exceeds MAX_LINE; nil at end of input.
    private def next_line(client : UNIXSocket) : String?
      loop do
        line = client.gets('\n', limit: MAX_LINE, chomp: false) || return
        return line.chomp if line.ends_with?('\n')
        return line if line.bytesize < MAX_LINE

        discard_rest(client)
      end
    end

    private def discard_rest(client : UNIXSocket) : Nil
      while piece = client.gets('\n', limit: MAX_LINE, chomp: false)
        break if piece.ends_with?('\n')
      end
    end

    private def append(line : String) : Nil
      @store_lock.synchronize { @log.write("#{line}\n".to_slice) }
    end
  end
end
