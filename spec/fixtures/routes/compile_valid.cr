require "../../../src/caramel"

module Fixture
  class TeamIndex < Caramel::Action
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  class TeamNew < Caramel::Action
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  class TeamShow < Caramel::Action
    contract do
      field team_id : Int64, min: 1
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: contract.team_id.to_s)
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  class TeamUpdate < Caramel::Action
    contract do
      field team_id : Int64, min: 1
      field name : String, max: 40
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  class MemberShow < Caramel::Action
    contract do
      field team_id : Int64
      field member_id : Int32
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  class FileShow < Caramel::Action
    contract do
      field name : String
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  Caramel::Router.draw do
    get "/", TeamIndex
    # Comments are allowed between routes.
    get "/teams/new", TeamNew
    get "/teams/:team_id", TeamShow
    patch "/teams/:team_id", TeamUpdate
    get "/teams/:team_id/members/:member_id", MemberShow
    get "/files/:name", FileShow
  end
end

Caramel::Application.new(Fixture::AppRouter.new, Caramel::CSRF.new("s" * 64, "https://example.caramel")).handle(HTTP::Request.new("GET", "/", HTTP::Headers{"Host" => "example.caramel"}))
