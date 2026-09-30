require "http"
require "../csrf"
require "../session"
require "./request_input"
require "./ingress"

module Caramel
  # Everything one action needs about its request: the parsed input, the CSRF
  # token for rendered forms, the signed session and the negotiated egress format.
  class RequestContext
    getter request : HTTP::Request
    getter input : RequestInput
    getter csrf_token : String
    getter ingress : Ingress
    @json_q = 0.0
    @html_q = 0.0
    @session : Hash(String, String)? = nil
    @loaded_session : Hash(String, String)? = nil

    def initialize(@request : HTTP::Request,
                   @csrf : CSRF,
                   @sessions : Session,
                   @input : RequestInput,
                   @ingress : Ingress = Ingress::DEFAULT)
      cookie = @request.cookies[CSRF::COOKIE_NAME]?.try(&.value)
      @csrf_token = cookie && @csrf.valid_token?(cookie) ? cookie : @csrf.issue
      negotiate(@request.headers["Accept"]?)
    end

    # The signed session, verified on first use; an invalid cookie reads as
    # empty. A route whose ingress turns CSRF off reads an empty session and
    # never saves it: another site's form carries the browser's cookie, so
    # the cookie cannot authenticate a request that skipped the CSRF check.
    def session : Hash(String, String)
      @session ||= begin
        loaded = saved_session || {} of String => String
        @loaded_session = loaded.dup
        loaded
      end
    end

    # The Set-Cookie that persists the session, or nil when it did not change.
    def session_cookie : HTTP::Cookie?
      current = @session
      @sessions.cookie(current) if @ingress.csrf? && current && current != @loaded_session
    end

    # What the session cookie holds, unless this route skipped the CSRF check.
    private def saved_session : Hash(String, String)?
      return unless @ingress.csrf?

      cookie = @request.cookies[Session::COOKIE_NAME]? || return
      @sessions.decode(cookie.value)
    end

    def method : String
      @input.method_override || @request.method
    end

    def htmx? : Bool
      @request.headers["HX-Request"]? == "true"
    end

    def partial? : Bool
      @request.headers["HX-Request-Type"]? == "partial"
    end

    def csrf_cookie : HTTP::Cookie
      @csrf.cookie(@csrf_token)
    end

    # htmx always asks for HTML, so JSON egress is only for explicit clients.
    def wants_json? : Bool
      !htmx? && @json_q > 0 && @json_q > @html_q
    end

    def browser? : Bool
      htmx? || @html_q > 0
    end

    # A request without Accept takes the HTML default; `*/*` alone selects
    # neither format.
    private def negotiate(accept : String?) : Nil
      unless accept
        @html_q = 1.0
        return
      end
      accept.split(',') do |range|
        parts = range.split(';')
        media_type = parts.first.strip.downcase
        next unless media_type == "application/json" || media_type == "text/html"
        q = 1.0
        parts.each(within: 1..) do |parameter|
          key, _, value = parameter.partition('=')
          q = quality(value) if key.strip.downcase == "q"
        end
        if media_type == "application/json"
          @json_q = q if q > @json_q
        else
          @html_q = q if q > @html_q
        end
      end
    end

    # A `q` parameter's weight, clamped to 0 through 1; one that is not a
    # finite number weighs 0.
    private def quality(value : String) : Float64
      number = value.strip.to_f64? || return 0.0
      number.finite? ? number.clamp(0.0, 1.0) : 0.0
    end
  end
end
