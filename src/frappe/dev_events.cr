require "socket"
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

    getter socket : String
    @server : UNIXServer? = nil

    def initialize(directory : String, log_directory : String, warnings : IO = STDERR)
      @socket = File.join(directory, "events-#{Random::Secure.hex(4)}.sock")
      @store = EventStore.new
      @store_lock = Mutex.new
      @store.replay(log_directory)
      @log = SiteLog.new(File.join(log_directory, EventStore::LOG_NAME), warnings, LOG_BYTES)
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

    def close : Nil
      @server.try(&.close)
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
        append(line) if event.is_a?(Crema::TraceEvent | Crema::ErrorEvent)
      end
    rescue IO::Error
      nil
    ensure
      client.close
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
