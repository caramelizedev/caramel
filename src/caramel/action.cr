require "json"
require "./response"
require "./html"
require "./hypermedia"
require "./islands"
require "./contracts/request_contract"
require "./http/request_context"

module Caramel
  # One instance handles one request. Subclasses declare a `contract` and
  # `def handle(contract : Contract)` returning either a `Caramel::Response`
  # or a JSON-serializable result that `render(result) : Page` turns into HTML.
  abstract class Action
    VARY = "Accept, HX-Request, HX-Request-Type"

    getter context : RequestContext
    property status : Int32 = 200

    def initialize(@context : RequestContext)
    end

    macro contract(&block)
      struct Contract < ::Caramel::RequestContract
        {{block.body}}
      end
    end

    # The full HTML document around a page body.
    abstract def layout(page : Page) : String

    def title_for(page : Page) : String
      page.title
    end

    def request : HTTP::Request
      @context.request
    end

    def csrf_token : String
      @context.csrf_token
    end

    def island(component : String, props) : HTML::Safe
      Island.tag(component, props)
    end

    def page(page : Page, status : Int32 = @status) : Response
      body = if @context.partial?
               # htmx extracts and removes this title before swapping a fragment.
               "<title>#{HTML.escape(title_for(page))}</title>#{page.body}"
             else
               layout(page)
             end
      Response.new(status, body, html_headers)
    end

    def partials(fragments : Enumerable(Partial), status : Int32 = @status) : Response
      Response.new(status, Hypermedia.render(fragments), html_headers)
    end

    def json(value, status : Int32 = @status) : Response
      headers = HTTP::Headers{"Content-Type" => "application/json", "Vary" => VARY, "Cache-Control" => "no-store"}
      Response.new(status, value.to_json, headers)
    end

    def redirect_to(path : String) : Response
      Response.navigate(request, path)
    end

    # A `Response` from `handle` passes through unchanged; any other result is
    # JSON for clients that prefer it and `respond_html` otherwise.
    def respond(outcome) : Response
      return outcome if outcome.is_a?(Response)
      @context.wants_json? ? json(outcome) : respond_html(outcome)
    end

    def respond_html(result) : Response
      page(render(result))
    end

    def render_contract_failure(contract : RequestContract) : Response
      if @context.wants_json?
        json({errors: contract.errors}, 422)
      elsif @context.browser?
        contract_failure_page(contract)
      else
        Response.new(422, contract.to_mrdp(@context.method, request.path), HTTP::Headers{"Content-Type" => "text/plain; charset=utf-8"})
      end
    end

    def contract_failure_page(contract : RequestContract) : Response
      html = String.build do |io|
        io << %(<section class="contract-errors" role="alert"><h1>Check your request</h1><ul>)
        contract.errors.each do |field, messages|
          messages.each do |message|
            io << "<li><code>" << HTML.escape(field) << "</code>: " << HTML.escape(message) << "</li>"
          end
        end
        io << "</ul></section>"
      end
      page(Page.new("Check your request", html), 422)
    end

    private def html_headers : HTTP::Headers
      headers = HTTP::Headers{"Content-Type" => "text/html; charset=utf-8", "Vary" => VARY, "Cache-Control" => "no-store"}
      headers.add("Set-Cookie", @context.csrf_cookie.to_set_cookie_header)
      headers
    end
  end
end
