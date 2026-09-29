require "json"
require "./response"
require "./html"
require "./hypermedia"
require "./islands"
require "./contracts/request_contract"
require "./http/ingress"
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

    # How this action's route reads its request; `ingress` replaces it.
    CARAMEL_INGRESS = ::Caramel::Ingress::DEFAULT

    # :nodoc:
    # The router calls this before the contract binds; `ingress authenticate:`
    # replaces it with a call to the named method.
    def __caramel_authenticated? : Bool
      true
    end

    # Declares how the route reads this action's request (ADR 0020):
    #
    # ```
    # ingress body: :raw,
    #   limit: 256.kilobytes,
    #   csrf: false,
    #   authenticate: :signed?
    # ```
    #
    # * `body: :raw` keeps the bytes exactly as sent, of any content type, for
    #   `raw_body`; the contract then binds only the route and the query. The
    #   default, `:form`, binds a form or a JSON object.
    # * `limit:` caps the body at a whole number of bytes, `N.kilobytes` or
    #   `N.megabytes`, up to 64 MiB. The default is 2 MiB.
    # * `authenticate: :method?` names an instance method returning `Bool`.
    #   It runs before the contract binds, and false answers 401.
    # * `csrf: false` skips the browser CSRF check. It requires an
    #   authenticator, and the session reads empty and is never saved: only a
    #   credential a browser does not attach on its own, such as a signature
    #   or a bearer token, can stand in for the check.
    macro ingress(*arguments, **options)
      {% site = @caller ? @caller.first : nil %}
      {% where = "" %}
      {% if site && site.filename %}
        {% position = "#{site.line_number}:#{site.column_number}" %}
        {% where = "\n  --> #{site.filename.id}:#{position.id}" %}
      {% end %}
      {% given = options.keys.map(&.id.stringify) %}
      {% keywords = ::Caramel::Ingress::KEYWORDS %}
      {% units = ::Caramel::Ingress::UNITS %}
      {% max = ::Caramel::Ingress::MAX_LIMIT %}
      {% example = ::Caramel::Ingress::EXAMPLE %}

      # Keywords only, once per action.
      {% if !arguments.empty? || options.empty? %}
        {% raise "ingress takes keywords: body:, limit:, csrf: and authenticate:" + where +
                 "\nRemediation: write, for example, `#{example.id}`.\n" %}
      {% end %}
      {% if @type.constants.map(&.stringify).includes?("CARAMEL_INGRESS") %}
        {% raise "#{@type} declares ingress twice#{where.id}" +
                 "\nRemediation: combine the keywords into one `ingress` declaration.\n" %}
      {% end %}
      {% for key, value in options %}
        {% unless keywords.includes?(key.id.stringify) %}
          {% value.raise "unknown ingress keyword '#{key}'; " +
                         "use body:, limit:, csrf: or authenticate:#{where.id}" %}
        {% end %}
      {% end %}

      # body: :form or :raw
      {% body = options[:body] %}
      {% kind = body.is_a?(SymbolLiteral) ? body.id.stringify : nil %}
      {% if given.includes?("body") && !["form", "raw"].includes?(kind) %}
        {% body.raise "ingress body: must be :form or :raw, got #{body}#{where.id}" %}
      {% end %}
      {% raw = kind == "raw" %}

      # limit: a whole number of bytes, N.kilobytes or N.megabytes
      {% limit = options[:limit] %}
      {% if given.includes?("limit") %}
        {% count = limit %}
        {% scale = 1 %}
        {% if limit.is_a?(Call) %}
          {% count = limit.receiver %}
          {% scale = limit.args.empty? ? units[limit.name.stringify] : nil %}
        {% end %}
        {% whole = count.is_a?(NumberLiteral) && !count.kind.id.starts_with?("f") %}
        {% bytes = whole && scale && count <= max ? count * scale : 0 %}
        {% unless 1 <= bytes && bytes <= max %}
          {% limit.raise "ingress limit: must be a whole number of bytes, " +
                         "N.kilobytes or N.megabytes from 1 byte to 64 MiB, " +
                         "got #{limit}#{where.id}" %}
        {% end %}
      {% end %}

      # csrf: true or false
      {% csrf = options[:csrf] %}
      {% if given.includes?("csrf") && !csrf.is_a?(BoolLiteral) %}
        {% csrf.raise "ingress csrf: must be true or false, got #{csrf}#{where.id}" %}
      {% end %}
      {% csrf = !given.includes?("csrf") || csrf %}

      # authenticate: :method?, required once csrf is off
      {% authenticate = options[:authenticate] %}
      {% if given.includes?("authenticate") %}
        {% method = authenticate.is_a?(SymbolLiteral) && authenticate.id.stringify %}
        {% unless method && method =~ /\A[a-z_]\w*[?!]?\z/ %}
          {% authenticate.raise "ingress authenticate: must name an instance method, " +
                                "as in :signed?, got #{authenticate}#{where.id}" %}
        {% end %}
      {% end %}
      {% if !csrf && !given.includes?("authenticate") %}
        {% raise "ingress csrf: false needs authenticate: :method? that verifies " +
                 "a credential a browser does not attach on its own, " +
                 "such as a signature or a bearer token" + where +
                 "\nRemediation: add `authenticate: :signed?` " +
                 "and define `private def signed? : Bool`.\n" %}
      {% end %}

      CARAMEL_INGRESS = ::Caramel::Ingress.new(
        body: ::Caramel::Ingress::Body::{{ raw ? "Raw".id : "Form".id }},
        limit: ({{ limit || "::Caramel::Ingress::DEFAULT_LIMIT".id }}).to_i64,
        csrf: {{ csrf }},
        authenticate: {{ authenticate ? authenticate.id.stringify : nil }},
      )

      {% if authenticate %}
        # :nodoc:
        def __caramel_authenticated? : Bool
          {{ authenticate.id }}
        end
      {% end %}

      {% if raw %}
        # The request body exactly as sent; empty for GET and HEAD.
        def raw_body : Bytes
          @context.input.raw_body
        end
      {% end %}
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
      page("Check your request", errors_html(contract.errors), 422)
    end

    # Answers errors found after the contract, such as a changeset's, the way
    # a contract failure is answered: JSON `{"errors": …}` for JSON clients, a
    # page listing them for browsers, and MRDP text for everyone else.
    def render_errors(errors : Hash(String, Array(String)),
                      status : Int32 = 422) : Response
      return json({errors: errors}, status) if @context.wants_json?
      return page("Check your request", errors_html(errors), status) if @context.browser?

      text = String.build do |io|
        io << "ERR INVALID:" << status
        io << " at " << @context.method << ' ' << request.path << '\n'
        errors.each do |field, messages|
          messages.each { |message| io << "FIELD " << field << ": " << message << '\n' }
        end
      end
      headers = HTTP::Headers{"Content-Type" => "text/plain; charset=utf-8"}
      Response.new(status, text, headers)
    end

    private def errors_html(errors : Hash(String, Array(String))) : String
      String.build do |io|
        io << %(<section class="contract-errors" role="alert">)
        io << %(<h1>Check your request</h1><ul>)
        errors.each do |field, messages|
          messages.each do |message|
            io << "<li><code>" << HTML.escape(field) << "</code>: "
            io << HTML.escape(message) << "</li>"
          end
        end
        io << "</ul></section>"
      end
    end

    private def html_headers : HTTP::Headers
      headers = HTTP::Headers{"Content-Type" => "text/html; charset=utf-8", "Vary" => VARY, "Cache-Control" => "no-store"}
      headers.add("Set-Cookie", @context.csrf_cookie.to_set_cookie_header)
      headers
    end
  end
end
