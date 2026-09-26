require "http"
require "../csrf"
require "./request_input"

module Caramel
  # Everything one action needs about its request: the parsed input, the CSRF
  # token for rendered forms and the negotiated egress format.
  class RequestContext
    getter request : HTTP::Request
    getter input : RequestInput
    getter csrf_token : String
    @json_q = 0.0
    @html_q = 0.0

    def initialize(@request : HTTP::Request, @csrf : CSRF, @input : RequestInput)
      cookie = @request.cookies[CSRF::COOKIE_NAME]?.try(&.value)
      @csrf_token = cookie && @csrf.valid_token?(cookie) ? cookie : @csrf.issue
      negotiate(@request.headers["Accept"]?)
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
          q = value.strip.to_f64?.try { |number| number.finite? ? number.clamp(0.0, 1.0) : 0.0 } || 0.0 if key.strip.downcase == "q"
        end
        if media_type == "application/json"
          @json_q = q if q > @json_q
        else
          @html_q = q if q > @html_q
        end
      end
    end
  end
end
