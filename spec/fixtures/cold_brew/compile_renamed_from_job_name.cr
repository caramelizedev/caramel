require "../../../src/caramel"

module App
  struct Restock < Caramel::ColdBrew::Job
    def perform
    end
  end

  struct RestockTea < Caramel::ColdBrew::Job
    renamed_from "App::Restock"

    def perform
    end
  end
end
