# Cold Brew alone, without the application's `jobs` command, so only `enqueue`
# types the whole-program check of job names.
require "../../../src/caramel/cold_brew"

module App
  struct Restock < Caramel::ColdBrew::Job
    renamed_from "App::Stock"

    def perform
    end
  end

  # Declares its old name once every job is defined, as generated jobs do.
  struct RestockTea < Caramel::ColdBrew::Job
    macro finished
      renamed_from "App::Stock"
    end

    def perform
    end
  end
end

App::Restock.enqueue
