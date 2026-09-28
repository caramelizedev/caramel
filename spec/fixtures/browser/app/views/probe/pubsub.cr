module App::Views::Probe
  class Pubsub < App::ApplicationView
    def initialize(@board : Int64)
    end

    private def blueprint
      h1 { "PubSub" }
      section id: "pubsub", data_board: @board do
        button(id: "pubsub-open", type: "button") { "Open the board stream" }
        button(id: "pubsub-ping", type: "button", hx_post: "/probe/pubsub/#{@board}/ping") { "Ping" }
        button(id: "pubsub-deliver", type: "button", hx_post: "/probe/pubsub/#{@board}/deliveries") { "Deliver" }
        form id: "pubsub-slow", hx_post: "/probe/pubsub/#{@board}/deliveries" do
          input type: "hidden", name: "pause_ms", value: "1500"
          button(id: "pubsub-deliver-slow", type: "submit") { "Deliver slowly" }
        end
        p do
          plain "Pinged: "
          output id: "pubsub-pinged"
          plain " Delivery: "
          output id: "pubsub-delivery"
        end
        ol id: "pubsub-log"
      end
    end
  end
end
