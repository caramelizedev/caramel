require "../../../src/caramel"

module Fixture
  struct TeamShow < Caramel::Action
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok"
    end
  end
end
