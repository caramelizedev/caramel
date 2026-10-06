require "socket"
require "./runtime"

module Caramel::Crema
  # Sends every finished trace, and every error outside a trace, to the
  # events socket `frappe dev` listens on, one JSON line each. A development
  # build requires this file; `Crema.start` attaches it only when
  # `CARAMEL_ENV=development` and `CARAMEL_DEV_EVENTS` names the socket.
  class DevSink < Sink
    CAPACITY = 1000
    PAUSE    = 1.second
    STOP     = 1.second

    alias Item = TraceEvent | ErrorEvent

    def initialize(@path : String)
      @events = Channel(Item).new(CAPACITY)
      @done = Channel(Nil).new
      @socket = nil.as(UNIXSocket?)
      @paused_until = Time.instant
    end

    def name : String
      "dev"
    end

    def records?(trace : Trace) : Bool
      true
    end

    def finished(trace : Trace) : Nil
      push(trace.to_event(Detail::Development))
    end

    # An error that is its trace's own travels in that trace; every other one goes alone.
    def reported(report : ErrorReport) : Nil
      return if Crema.current?.try(&.error) == report

      push(report.to_event(Detail::Development))
    end

    def start : self
      spawn(name: "crema:dev") { run }
      self
    end

    # Closes the queue and waits briefly for the writer to finish.
    def stop : Nil
      @events.close
      select
      when @done.receive?
      when timeout(STOP)
      end
    end

    private def push(item : Item) : Nil
      select
      when @events.send(item)
      else
        Crema.drop("dev")
      end
    rescue Channel::ClosedError
      nil
    end

    private def run : Nil
      while item = @events.receive?
        deliver(item)
      end
    ensure
      @socket.try(&.close)
      @done.close
    end

    private def deliver(item : Item) : Nil
      if Time.instant < @paused_until
        Crema.drop("dev")
        return
      end
      socket = @socket ||= UNIXSocket.new(@path)
      socket << item.to_json << '\n'
      socket.flush
    rescue
      Crema.drop("dev")
      @socket.try { |open| open.close rescue nil }
      @socket = nil
      @paused_until = Time.instant + PAUSE
    end
  end

  on_start do |_|
    path = ENV["CARAMEL_DEV_EVENTS"]?
    if development? && path
      sink = DevSink.new(path).start
      subscribe(sink)
      -> do
        unsubscribe(sink)
        sink.stop
        nil
      end
    end
  end
end
