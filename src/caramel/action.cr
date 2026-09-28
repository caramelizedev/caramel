require "json"
require "./response"
require "./html"
require "./hypermedia"
require "./islands"
require "./contracts/request_contract"
require "./http/request_context"
require "./view"

module Caramel
  # One instance handles one request. Subtypes declare a `contract` and
  # `def handle(contract : Contract)` returning either a `Caramel::Response`
  # or a JSON-serializable result that `render(result)` turns into HTML.
  abstract struct Action
    VARY = "Accept, HX-Request, HX-Request-Type"

    getter context : RequestContext
    property status : Int32 = 200

    def initialize(@context : RequestContext)
    end

    # CARAMEL_CONTRACT_LOCATION records where `contract do` was written, so the
    # router's mismatch errors can point tools at the block to patch.
    macro contract(&block)
      struct Contract < ::Caramel::RequestContract
        {% call = @caller ? @caller.first : nil %}
        {% if call && call.filename %}
          CARAMEL_CONTRACT_LOCATION = {{ "#{call.filename.id}:#{call.line_number}:#{call.column_number}" }}
        {% end %}
        {{ block.body }}
      end
    end

    # The full HTML document around a page body. Applications override it
    # (the generated ApplicationAction renders its layout view); actions that
    # only stream, morph or answer JSON never need to.
    def layout(page : Page) : String
      %(<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>#{HTML.escape(title_for(page))}</title></head><body>#{page.body}</body></html>)
    end

    def title_for(page : Page) : String
      page.title
    end

    def request : HTTP::Request
      @context.request
    end

    def csrf_token : String
      @context.csrf_token
    end

    # The signed session; changes are saved in the response's cookie.
    def session : Hash(String, String)
      @context.session
    end

    def sign_out : Nil
      @context.session.clear
    end

    def island(component : String, props) : HTML::Safe
      Island.tag(component, props)
    end

    def page(title : String, body : String, status : Int32 = @status) : Response
      page = Page.new(title, body)
      html = if @context.partial?
               # htmx extracts and removes this title before swapping a fragment.
               "<title>#{HTML.escape(title_for(page))}</title>#{page.body}"
             else
               layout(page)
             end
      Response.new(status, html, html_headers)
    end

    # Renders `body`, a view, as the page.
    def page(title : String, body : View, status : Int32 = @status) : Response
      page(title, body.to_s, status)
    end

    # Renders `body`, trusted HTML such as `markup { … }`, as the page.
    def page(title : String, body : HTML::Safe, status : Int32 = @status) : Response
      page(title, body.value, status)
    end

    # Builds a fragment too small for a view class, with a view's escaping:
    # `morph "#count", with: markup { span { count.to_s } }`. Inside the block,
    # element methods such as `label` or `title` come first; the action's other
    # methods and locals stay available.
    def markup(&) : HTML::Safe
      HTML::Safe.new(Blueprint::HTML::Builder.build { |builder| with builder yield })
    end

    def partials(fragments : Enumerable(Partial), status : Int32 = @status) : Response
      Response.new(status, Hypermedia.render(fragments), html_headers)
    end

    # Replaces one target's content with `html`, a view or trusted HTML.
    def morph(target : String, with html, swap : String = "innerMorph", status : Int32 = @status) : Response
      partials([Partial.new(target, html.to_s, swap)], status)
    end

    def json(value, status : Int32 = @status) : Response
      headers = HTTP::Headers{"Content-Type" => "application/json", "Vary" => VARY, "Cache-Control" => "no-store"}
      Response.new(status, value.to_json, headers)
    end

    def redirect_to(path : String) : Response
      Response.navigate(request, path)
    end

    # Sends the browser to another site; `url` must be an absolute http(s) URL.
    def redirect_external(url : String, status : Int32 = 302) : Response
      Response.redirect_external(request, url, status)
    end

    def not_found(message : String = "Not found") : Response
      Response.new(404, message)
    end

    # Streams the body; uploaded files are already deleted when the block runs.
    def stream(content_type : String, status : Int32 = @status, &block : IO -> Nil) : Response
      Response.stream(status, HTTP::Headers{"Content-Type" => content_type, "Cache-Control" => "no-store", "Vary" => VARY}, &block)
    end

    # A `Response` from `handle` passes through unchanged; any other result is
    # JSON for clients that prefer it and `render(result)` otherwise.
    # `render(result)` is the action's own HTML egress (a page, redirect,
    # morph, …); a missing `render` for a non-Response result is a compile error.
    def respond(outcome) : Response
      return outcome if outcome.is_a?(Response)
      @context.wants_json? ? json(outcome) : render(outcome)
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
      page("Check your request", html, 422)
    end

    private def html_headers : HTTP::Headers
      headers = HTTP::Headers{"Content-Type" => "text/html; charset=utf-8", "Vary" => VARY, "Cache-Control" => "no-store"}
      headers.add("Set-Cookie", @context.csrf_cookie.to_set_cookie_header)
      headers
    end
  end
end
