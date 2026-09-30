module Caramel
  # Server-sent event framing (the WHATWG `text/event-stream` format).
  module SSE
    # Writes one event and flushes. Each line of `data` becomes its own
    # `data:` field, so the browser receives `data` unchanged.
    #
    #     stream "text/event-stream" do |io|
    #       Caramel::ColdBrew.subscribe("board_#{id}") do |updates|
    #         loop { Caramel::SSE.write(io, event: "BoardUpdated", data: updates.receive) }
    #       end
    #     end
    def self.write(io : IO, data : String, event : String? = nil) : Nil
      if event
        if event.includes?('\n') || event.includes?('\r')
          raise ArgumentError.new("SSE event names cannot contain line breaks")
        end
        io << "event: " << event << '\n'
      end
      data.split(/\r\n|\r|\n/).each { |line| io << "data: " << line << '\n' }
      io << '\n'
      io.flush
    end
  end
end
