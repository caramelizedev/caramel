require "../../../src/caramel"

module App
  abstract struct Mail < Caramel::ColdBrew::Job
    renamed_from "App::Letter"
  end

  struct Welcome < Mail
    def perform
    end
  end
end
