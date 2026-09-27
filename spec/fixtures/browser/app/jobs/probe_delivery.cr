module App
  # Marks a delivery done and announces it; the publish commits with the job.
  # `pause_ms` keeps the job running while the check sends SIGTERM.
  struct ProbeDelivery < Caramel::ColdBrew::Job
    param delivery_id : Int64
    param board_id : Int64
    param pause_ms : Int32 = 0

    def perform
      sleep pause_ms.milliseconds
      SugarORM.sql_exec("UPDATE probe_deliveries SET delivered_at = now() WHERE id = $1", delivery_id)
      Caramel::ColdBrew.publish("board_#{board_id}", {delivery: delivery_id}.to_json)
    end
  end
end
