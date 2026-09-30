require "../../../src/caramel"

module Fixture
  struct TeamIndex < Caramel::Action
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  struct TeamNew < Caramel::Action
    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(body: "ok")
    end

    def layout(page : Caramel::Page) : String
      page.body
    end
  end

  struct TeamShow < Caramel::Action
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

  struct TeamUpdate < Caramel::Action
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

  struct MemberShow < Caramel::Action
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

  struct FileShow < Caramel::Action
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

  struct Webhook < Caramel::Action
    ingress body: :raw, limit: 256.kilobytes, csrf: false, authenticate: :signed?

    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(202, String.new(raw_body))
    end

    def layout(page : Caramel::Page) : String
      page.body
    end

    private def signed? : Bool
      request.headers.has_key?("X-Signature")
    end
  end

  # An API base declares ingress once; subtypes inherit or replace it.
  abstract struct Api < Caramel::Action
    ingress csrf: false, authenticate: :token?

    def layout(page : Caramel::Page) : String
      page.body
    end

    private def token? : Bool
      request.headers["Authorization"]? == "Bearer token"
    end
  end

  struct NoteCreate < Api
    contract do
      field title : String
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(201, contract.title)
    end
  end

  struct NoteImport < Api
    ingress body: :raw, limit: 1_048_576, csrf: false, authenticate: :token?

    contract do
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(202, raw_body.size.to_s)
    end
  end

  Caramel::Router.draw do
    post "/hooks/inbox", Webhook
    post "/notes", NoteCreate
    post "/notes/import", NoteImport
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
