require "../../../src/caramel"

module App
  struct Restock < Caramel::ColdBrew::Job
    renamed_from "App::Stock"

    def perform
    end
  end

  struct RestockTea < Caramel::ColdBrew::Job
    renamed_from "App::Stock"

    def perform
    end
  end
end
