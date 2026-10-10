require "../../../src/caramel"

module App
  struct RestockTea < Caramel::ColdBrew::Job
    renamed_from "::App::Restock"

    def perform
    end
  end
end
