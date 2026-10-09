require "../../../src/caramel"

module App
  struct RestockTea < Caramel::ColdBrew::Job
    renamed_from "App::Restock"
    renamed_from "App::Stock"

    def perform
    end
  end
end
