module App::Probe
  # The stream's second event waits until the check requests release.
  RELEASE = Channel(Nil).new

  struct Events < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      page "Server-sent events", view("probe/events")
    end
  end

  struct Stream < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      stream "text/event-stream" do |io|
        io << "event: probe\ndata: first\n\n"
        io.flush
        second = select
        when RELEASE.receive
          "second"
        when timeout(60.seconds)
          "timeout"
        end
        io << "event: probe\ndata: " << second << "\n\n"
        io.flush
      end
    end
  end

  struct Release < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      select
      when RELEASE.send(nil)
        Caramel::Response.new(body: "released")
      when timeout(5.seconds)
        Caramel::Response.new(409, "No stream is waiting")
      end
    end
  end
end
