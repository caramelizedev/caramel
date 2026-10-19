require "http/server"
require "mime"
require "uuid"
require "log"
require "./crema"
require "./csrf"
require "./http/request_input"
require "./http/request_context"
require "./content_security_policy"
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

    # What `serve` sends in production: one year, for this host only. There is no
    # `includeSubDomains` or `preload`, because a parent domain may serve sites that
    # are not HTTPS-only.
    STRICT_TRANSPORT_SECURITY = "max-age=31536000"

    getter csrf : CSRF
    getter sessions : Session
    @authority : String
    @public_root : String?
    @policy : ContentSecurityPolicy
    @policy_header : String
    @in_flight = Atomic(Int32).new(0)
    @draining = Atomic(Bool).new(false)

    def initialize(@router : Router::Dispatcher,
                   @csrf : CSRF,
                   public_root : String? = nil,
                   policy : ContentSecurityPolicy = Caramel.content_security_policy,
                   @hsts : Bool = false)
      @policy = policy.dup
      @policy_header = @policy.to_s
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
      Crema.request(request) do
        secure(tenanted(request) { |found| localized(found) { |routed| route(routed) } })
      end
    end

    def call(context : HTTP::Server::Context) : Nil
      @in_flight.add(1)
      begin
        response = handle(context.request)
        context.response.status_code = response.status
        response.headers.each { |name, values| context.response.headers[name] = values }
        context.response.headers["Connection"] = "close" if @draining.get
        if streamer = response.streamer
          streaming(response) do
            streamer.call(context.response)
          rescue IO::Error | HTTP::Server::ClientError
            # The client disconnected; the server wraps socket errors in ClientError.
          rescue error : Channel::ClosedError
            # A closed subscription ends a stream at the first signal; outside a drain it is
            # a fault.
            report_stream(error, response) unless @draining.get
          rescue error
            report_stream(error, response)
          end
        else
          context.response.print(response.body)
        end
      ensure
        @in_flight.sub(1)
      end
    end

    # Starts shutdown: every response written from now on closes its connection.
    def drain : Nil
      @draining.set(true)
    end

    # How many requests are in flight.
    def in_flight : Int32
      @in_flight.get
    end

    # The status line has already been sent; the request id joins this report to the
    # request's canonical line.
    private def report_stream(error : Exception, response : Response) : Nil
      request_id = response.headers["X-Request-ID"]?
      Crema.report(error, handled: false, source: "stream", request_id: request_id)
    end

    # Waits until no request is in flight or *timeout* passes, and returns how many remain.
    def wait_idle(timeout : Time::Span) : Int32
      deadline = Time.instant + timeout
      while @in_flight.get > 0 && Time.instant < deadline
        sleep 25.milliseconds
      end
      @in_flight.get
    end

    # Reads, checks and dispatches one request. Every failure becomes a
    # response; `handle` secures them all.
    private def route(request : HTTP::Request) : Response
      # The route decides how its body is read and whether CSRF guards it;
      # a request that matches none reads and is checked as a form.
      match = @router.match(request)
      input = RequestInput.read(request, match.ingress, uploads: match.uploads)
      context = RequestContext.new(request, @csrf, @sessions, input, match.ingress, @policy)
      if RequestInput::BODY_METHODS.includes?(request.method) && match.ingress.csrf?
        token = input.csrf_token || request.headers["X-CSRF-Token"]?
        raise Forbidden.new unless @csrf.valid?(request, token)
      end
      response = @router.dispatch(context, match)
      if header = context.content_security_policy_header
        response.headers["Content-Security-Policy"] = header
      end
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
      failure(error, request)
    ensure
      input.try(&.cleanup)
    end

    # The 500 response to *error*, an exception routing *request* raised.
    private def failure(error : Exception, request : HTTP::Request) : Response
      # The report holds a redacted message for the in-memory error ring only; logs and
      # responses carry its class and fingerprint, since dependency errors may include
      # connection URLs, form values, or other secrets.
      report = Crema.report(error, handled: false)
      {% if flag?(:caramel_development) %}
        if ENV["CARAMEL_ENV"]? == "development"
          return DevelopmentError.response(error, report, request)
        end
      {% end %}
      request_id = report.request_id
      headers = HTTP::Headers{
        "X-Request-ID"  => request_id || "",
        "Cache-Control" => "no-store",
        "Content-Type"  => "text/plain; charset=utf-8",
      }
      Response.new(500, "Something went wrong. Reference: #{request_id}", headers)
    end

    # Routes *request* in its tenant. `caramel/tenancy` replaces this to find
    # the tenant its first path segment names and strip that segment.
    private def tenanted(request : HTTP::Request, & : HTTP::Request -> Response) : Response
      yield request
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
      unless response.headers.has_key?("Content-Security-Policy")
        response.headers["Content-Security-Policy"] = @policy_header
      end
      response.headers["Strict-Transport-Security"] = STRICT_TRANSPORT_SECURITY if @hsts
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
