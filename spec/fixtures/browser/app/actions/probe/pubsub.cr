module App::Probe
  PUBSUB_BOARD = 42_i64

  struct Pubsub < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      page "PubSub", Views::Probe::Pubsub.new(PUBSUB_BOARD)
    end
  end

  # The Boards::Live streaming action.
  struct Live < App::ApplicationAction
    contract do
      field board_id : Int64
    end

    def handle(contract : Contract)
      channel = Channel(String).new
      Caramel::ColdBrew.subscribe("board_#{contract.board_id}", channel)

      stream "text/event-stream" do |io|
        loop do
          io << "event: BoardUpdated\ndata: " << channel.receive << "\n\n"
          io.flush
        end
      end
    end
  end

  # The stream sends its headers with its first event; a ping outside any
  # transaction tells the check that the stream is live.
  struct Ping < App::ApplicationAction
    contract do
      field board_id : Int64
    end

    def handle(contract : Contract)
      Caramel::ColdBrew.publish("board_#{contract.board_id}", "ping")
      morph("#pubsub-pinged", "yes", swap: "innerHTML")
    end
  end

  # The business row and its job commit together; serve's worker runs the job.
  struct Deliver < App::ApplicationAction
    contract do
      field board_id : Int64
      field pause_ms : Int32, min: 0, max: 5000, default: 0
    end

    def handle(contract : Contract)
      delivery = 0_i64
      SugarORM::Repo.transaction do
        delivery = SugarORM.sql("INSERT INTO probe_deliveries (board_id) VALUES ($1) RETURNING id", contract.board_id, as: {id: Int64}).first[:id]
        App::ProbeDelivery.enqueue(delivery_id: delivery, board_id: contract.board_id, pause_ms: contract.pause_ms)
      end
      morph("#pubsub-delivery", delivery.to_s, swap: "innerHTML")
    end
  end
end
