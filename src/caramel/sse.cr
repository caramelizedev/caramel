module Caramel
  # Server-sent event framing (the WHATWG `text/event-stream` format).
  module SSE
    # How long `relay` lets a stream stay silent before it writes a comment.
    HEARTBEAT = 15.seconds

    # Writes one event and flushes. Each line of `data` becomes its own
    # `data:` field, so the browser receives `data` unchanged.
    def self.write(io : IO, data : String, event : String? = nil) : Nil
      if event
        refuse_line_breaks(event, "event names")
        io << "event: " << event << '\n'
      end
      data.split(/\r\n|\r|\n/).each { |line| io << "data: " << line << '\n' }
      io << '\n'
      io.flush
    end

    # Writes a comment line and flushes. The browser ignores it, and the write
    # fails on a connection the client has dropped.
    def self.comment(io : IO, text : String = "") : Nil
      refuse_line_breaks(text, "comments")
      io << ": " << text << "\n\n"
      io.flush
    end

    # Writes each payload of `updates` as an event, with a `: ping` comment
    # after each `heartbeat` without one, so a dropped client fails the
    # stream at the next heartbeat (`IO::Error`) instead of at the next event.
    # Returns when `updates` closes.
    #
    #     stream "text/event-stream" do |io|
    #       Caramel::ColdBrew.subscribe("board_#{id}") do |updates|
    #         Caramel::SSE.relay(io, updates, event: "BoardUpdated")
    #       end
    #     end
    def self.relay(io : IO,
                   updates : Channel(String),
                   event : String? = nil,
                   heartbeat : Time::Span = HEARTBEAT) : Nil
      loop do
        select
        when data = updates.receive?
          return unless data
          write(io, data, event)
        when timeout(heartbeat)
          comment(io, "ping")
        end
      end
    end

    private def self.refuse_line_breaks(text : String, what : String) : Nil
      return unless text.includes?('\n') || text.includes?('\r')
      raise ArgumentError.new("SSE #{what} cannot contain line breaks")
    end
  end
end
