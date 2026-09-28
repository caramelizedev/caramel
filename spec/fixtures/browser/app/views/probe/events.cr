module App::Views::Probe
  class Events < App::ApplicationView
    private def blueprint
      h1 { "Server-sent events" }
      button(id: "sse-open", type: "button") { "Open the stream" }
      ol id: "sse-log"
    end
  end
end
