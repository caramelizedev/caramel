require "spec"
require "../../src/caramel"

# What libraries outside the framework use of an action; each declaration's comment says
# so. An example that fails, or no longer compiles, means such a library breaks.

# An error of a library's own, which an action's `handle` raises.
class LibraryHooksRefusal < Exception
end

abstract struct LibraryHooksAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

# Answers as the framework does.
struct LibraryHooksSeated < LibraryHooksAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    Caramel::Response.new(body: "seated")
  end
end

# Redefines the hook as a library does: with the framework's signature, and reaching
# `Egress` by its short name.
struct LibraryHooksRefusing < LibraryHooksAction
  contract do
  end

  def handle(contract : Contract) : Caramel::Response
    raise LibraryHooksRefusal.new("no seats left")
  end

  def __caramel_answer(contract : Caramel::RequestContract,
                       & : -> Caramel::Response) : Caramel::Response
    yield
  rescue error : LibraryHooksRefusal
    errors = {"_base" => [error.message.to_s]}
    Egress.text(422, Egress.errors_text(errors, 422, @context.method, request.path))
  end
end

module LibraryHooksApp
  Caramel::Router.draw do
    get "/seats", LibraryHooksSeated
    get "/refusals", LibraryHooksRefusing
  end
end

private alias Egress = Caramel::Action::Egress

private REFUSED = <<-TEXT
  ERR INVALID:422 at GET /refusals
  FIELD _base: no seats left

  TEXT

private def context(path : String) : Caramel::RequestContext
  request = HTTP::Request.new("GET", path)
  csrf = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
  session = Caramel::Session.new(csrf.derive_keys("session"))
  Caramel::RequestContext.new(request, csrf, session, Caramel::RequestInput.read(request))
end

private def route(path : String) : Caramel::Response
  LibraryHooksApp::AppRouter.new.dispatch(context(path))
end

describe "Caramel's hooks for libraries" do
  it "answers with what the block returns through __caramel_answer" do
    seats = context("/seats")
    action = LibraryHooksSeated.new(seats)
    contract = LibraryHooksSeated::Contract.parse(seats.input)
    served = Caramel::Response.new(body: "served")
    answer = action.__caramel_answer(contract: contract) { served }
    answer.body.should eq("served")
    typeof(answer).should eq(Caramel::Response)
  end

  it "answers a route through the action's own __caramel_answer" do
    route("/seats").body.should eq("seated")
    refused = route("/refusals")
    refused.status.should eq(422)
    refused.body.should eq(REFUSED)
  end

  it "builds a plain-text response through Egress.text" do
    response = Egress.text(status: 422, body: "no seats left")
    response.status.should eq(422)
    response.body.should eq("no seats left")
    response.headers["Content-Type"].should eq("text/plain; charset=utf-8")
    typeof(response).should eq(Caramel::Response)
  end

  it "writes a refused request's errors as text through Egress.errors_text" do
    errors = {"_base" => ["no seats left"]}
    text = Egress.errors_text(errors: errors, status: 422, method: "GET", path: "/refusals")
    text.should eq(REFUSED)
  end
end
