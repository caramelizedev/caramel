require "http/server"
require "mime"
require "uuid"
require "log"
require "./csrf"
require "./http/request_input"
require "./http/request_context"
require "./http/router"
require "./wording"
{% if flag?(:caramel_development) %}
  require "./development_error"
{% end %}

module Caramel
  class Forbidden < Exception; end

  # The HTTP server is a private upstream behind the trusted local proxy. Host
  # validation uses the configured origin; forwarded headers grant no trust.
  class Application
    include HTTP::Handler

    CONTENT_SECURITY_POLICY = "default-src 'self'; script-src 'self'; style-src 'self'; " \
                              "img-src 'self' data:; base-uri 'self'; form-action 'self'; " \
                              "frame-ancestors 'none'; object-src 'none'"

    getter csrf : CSRF
    getter sessions : Session
    @authority : String
    @public_root : String?

    def initialize(@router : Router::Dispatcher, @csrf : CSRF, public_root : String? = nil)
      @authority = URI.parse(@csrf.origin).authority ||
                   raise ArgumentError.new("Application origin #{@csrf.origin} has no host")
      @public_root = public_root.try { |root| File.realpath(root) }
      @sessions = Session.new(@csrf.derive_key("session"))
    end

    def handle(request : HTTP::Request) : Response
      return secure(Response.new(400, "Malformed path")) unless request.path.starts_with?("/")
      host = request.headers["Host"]?
      return secure(Response.new(421, "Unknown project host")) if host != @authority
      if static = static_response(request)
        return secure(static)
      end
      secure(localized(request) { |routed| route(routed) })
    end

    def call(context : HTTP::Server::Context) : Nil
      response = handle(context.request)
      context.response.status_code = response.status
      response.headers.each { |name, values| context.response.headers[name] = values }
      if streamer = response.streamer
        streaming(response) do
          streamer.call(context.response)
        rescue IO::Error | HTTP::Server::ClientError
          # The client disconnected; the server wraps socket errors in ClientError.
        rescue error
          # The status line has already been sent; only the log can report this.
          Log.error { "request_id=#{UUID.random} error_type=#{error.class} streaming=true" }
        end
      else
        context.response.print(response.body)
      end
    end

    # Reads, checks and dispatches one request. Every failure becomes a
    # response; `handle` secures them all.
    private def route(request : HTTP::Request) : Response
      # The route decides how its body is read and whether CSRF guards it;
      # a request that matches none reads and is checked as a form.
      match = @router.match(request)
      input = RequestInput.read(request, match.ingress)
      context = RequestContext.new(request, @csrf, @sessions, input, match.ingress)
      if RequestInput::BODY_METHODS.includes?(request.method) && match.ingress.csrf?
        token = input.csrf_token || request.headers["X-CSRF-Token"]?
        raise Forbidden.new unless @csrf.valid?(request, token)
      end
      response = @router.dispatch(context, match)
      if cookie = context.session_cookie
        response.headers.add("Set-Cookie", cookie.to_set_cookie_header)
      end
      response
    rescue Forbidden
      Response.new(403, Wording.expired_form)
    rescue RequestInput::TooLarge
      Response.new(413, "Request body is too large")
    rescue RequestInput::UnsupportedMediaType
      Response.new(415, RequestInput::UNSUPPORTED)
    rescue RequestInput::InvalidEncoding
      Response.new(400, "Malformed request")
    rescue error
      request_id = UUID.random.to_s
      # Do not log arbitrary exception messages: dependency errors may include
      # connection URLs, form values, or other secrets.
      Log.error { "request_id=#{request_id} error_type=#{error.class}" }
      {% if flag?(:caramel_development) %}
        if ENV["CARAMEL_ENV"]? == "development"
          return DevelopmentError.response(error, request_id, request)
        end
      {% end %}
      headers = HTTP::Headers{
        "X-Request-ID"  => request_id,
        "Cache-Control" => "no-store",
        "Content-Type"  => "text/plain; charset=utf-8",
      }
      Response.new(500, "Something went wrong. Reference: #{request_id}", headers)
    ensure
      input.try(&.cleanup)
    end

    # Routes *request*. `caramel/i18n` replaces this to resolve the request's
    # locale around routing.
    private def localized(request : HTTP::Request, & : HTTP::Request -> Response) : Response
      yield request
    end

    # Writes a streamed body. `caramel/i18n` replaces this to keep the
    # response's locale while it streams.
    private def streaming(response : Response, &) : Nil
      yield
    end

    private def secure(response : Response) : Response
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Referrer-Policy"] = "same-origin"
      response.headers["Content-Security-Policy"] = CONTENT_SECURITY_POLICY
      response
    end

    private def static_response(request : HTTP::Request) : Response?
      root = @public_root
      return unless root
      path = request.path
      return Response.new(400, "Malformed path") if path.matches?(/%(?![0-9a-fA-F]{2})/)
      decoded = URI.decode(path)
      return Response.new(404, "Not found") if unsafe_path?(decoded)
      candidate = File.expand_path(".#{decoded}", root)
      return unless candidate.starts_with?(root + "/") && File.file?(candidate)
      real = File.realpath(candidate)
      return Response.new(404, "Not found") unless real.starts_with?(root + "/")
      unless {"GET", "HEAD"}.includes?(request.method)
        return Response.new(405, "Method not allowed", HTTP::Headers{"Allow" => "GET, HEAD"})
      end
      headers = HTTP::Headers{
        "Content-Type"   => MIME.from_filename(real, "application/octet-stream"),
        "Content-Length" => File.size(real).to_s,
      }
      Response.new(200, request.method == "HEAD" ? "" : File.read(real), headers)
    end

    # A decoded path with a NUL byte, a backslash or a segment that starts
    # with a dot is never served.
    private def unsafe_path?(decoded : String) : Bool
      return true if decoded.includes?('\0') || decoded.includes?('\\')
      decoded.split('/').any?(&.starts_with?('.'))
    end
  end
end
