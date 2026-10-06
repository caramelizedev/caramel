require "http/server"
require "http/client"
require "socket/unix_socket"
require "crypto/subtle"
require "./project"
require "./diagnostics"
require "./dev_events"
require "./inspector"
require "../caramel/html"
require "../caramel/crema/editor"
require "../caramel/crema/redact"
require "../caramel/response"

module Caramel::Frappe
  # One stable, private socket sits behind Latte's HTTPS proxy. Only ready
  # builds receive application traffic; diagnostics and refresh stay local.
  class DevGateway
    include HTTP::Handler
    COOKIE          = "__Host-caramel_dev"
    CLIENT          = {{ read_file("#{__DIR__}/dev_client.js") }}
    INSPECTOR_STYLE = {{ read_file("#{__DIR__}/inspector.css") }}
    TOOLBAR_STYLE   = {{ read_file("#{__DIR__}/dev_toolbar.css") }}
    PREFIX          = "/__caramel/dev/"

    # The diagnostic page's stylesheet.
    STYLE = "body{max-width:960px;margin:8vh auto;padding:24px;font:16px/1.6 system-ui;" \
            "background:#faf8f3;color:#332d27}h1{font:44px Georgia}" \
            "pre{white-space:pre-wrap;overflow-wrap:anywhere;padding:24px;" \
            "background:#fff;border:1px solid #e5dfd4;border-radius:8px}" \
            "p{color:#786f65}"

    CONTENT_SECURITY_POLICY = "default-src 'self'; script-src 'self'; " \
                              "style-src 'self'; base-uri 'none'; " \
                              "frame-ancestors 'none'; object-src 'none'"

    # Connection-level headers a proxy must not pass on.
    HOP_HEADERS = %w[
      Connection Keep-Alive Proxy-Authenticate Proxy-Authorization
      TE Trailer Transfer-Encoding Upgrade
    ]

    getter generation : Int64 = 0_i64
    getter owner_token : String = Random::Secure.hex(32)
    getter state : String = "building"
    @message = "Compiling your application…"
    @upstream : String? = nil
    @token = Random::Secure.hex(32)
    @authority : String
    @events : DevEvents? = nil
    @inspector : Inspector? = nil
    @diagnostics = [] of Diagnostic
    @endpoints : Hash(String, Proc(HTTP::Request, Caramel::Response))

    # *editor* and *root* turn compiler locations and queries into links that open
    # the file; the inspector needs `events`, which the session sets once it exists.
    def initialize(@origin : String,
                   @secrets : Array(String) = [] of String,
                   @editor : Crema::Editor = Crema::Editor.from(nil),
                   @root : String? = nil)
      uri = URI.parse(@origin)
      https = uri.scheme == "https" && uri.host && uri.path.empty?
      raise Error.new("Development requires an HTTPS origin") unless https
      @authority = uri.authority || raise Error.new("Development requires an HTTPS origin")
      @endpoints = endpoints
    end

    # The spans of other services that Latte's collector holds for a trace id, for the
    # inspector's "Across services"; none by default.
    property collected : Crema::CollectedLookup = Crema::NO_COLLECTED

    # The development event store behind the inspector and the toolbar.
    def events=(events : DevEvents?) : DevEvents?
      @events = events
      @inspector = events.try { |store| Inspector.new(store, @editor, @root || "", @collected) }
      events
    end

    def events : DevEvents?
      @events
    end

    def building : Nil
      @state = "building"
      @message = "Compiling your application…"
      @diagnostics = [] of Diagnostic
    end

    def ready(socket : String) : Nil
      @upstream = socket
      @state = "ready"
      @generation += 1
    end

    # Shows *message*, and *diagnostics* parsed from it as links to the code.
    def failed(message : String, diagnostics : Array(Diagnostic) = [] of Diagnostic) : Nil
      safe_message = redact(message)
      return if @state == "failed" && @message == safe_message
      @state = "failed"
      @message = safe_message
      @diagnostics = diagnostics
      @generation += 1
    end

    def assets_changed : Nil
      @generation += 1
    end

    def handle(request : HTTP::Request) : Caramel::Response
      unless request.headers["Host"]? == @authority
        return secure(Caramel::Response.new(421, "Unknown project host"))
      end
      if request.path.starts_with?("/__caramel/dev/")
        return endpoint(request)
      end
      if @state == "ready" && (socket = @upstream)
        return forward(request, socket, @generation)
      end
      diagnostic(request)
    end

    def call(context : HTTP::Server::Context) : Nil
      response = handle(context.request)
      context.response.status_code = response.status
      response.headers.each { |name, values| context.response.headers[name] = values }
      return if context.request.method == "HEAD"
      if streamer = response.streamer
        begin
          streamer.call(context.response)
        rescue IO::Error | HTTP::Server::ClientError
          # The browser closed the stream; the server wraps socket errors in ClientError.
        end
      else
        context.response.print(response.body)
      end
    end

    private def endpoint(request : HTTP::Request) : Caramel::Response
      unless request.method == "GET"
        return secure(Caramel::Response.new(405, "Method not allowed"))
      end
      path = request.path
      inspector_path = "#{PREFIX}inspector"
      prefixed = path.starts_with?(inspector_path) && !path.ends_with?(".css")
      return inspector_page(request) if prefixed
      handler = @endpoints[path]? || return secure(Caramel::Response.new(404, "Not found"))
      handler.call(request)
    end

    # The development endpoints by path: assets, status and the traces feed.
    private def endpoints : Hash(String, Proc(HTTP::Request, Caramel::Response))
      {
        "#{PREFIX}client.js"     => ->(_request : HTTP::Request) { script_asset(CLIENT) },
        "#{PREFIX}style.css"     => ->(_request : HTTP::Request) { stylesheet(STYLE) },
        "#{PREFIX}inspector.css" => ->(_request : HTTP::Request) { stylesheet(INSPECTOR_STYLE) },
        "#{PREFIX}toolbar.css"   => ->(_request : HTTP::Request) { stylesheet(TOOLBAR_STYLE) },
        "#{PREFIX}status"        => ->(request : HTTP::Request) { status(request) },
        "#{PREFIX}traces.json"   => ->(request : HTTP::Request) { traces_feed(request) },
      }
    end

    private def script_asset(body : String) : Caramel::Response
      ok(body, "text/javascript; charset=utf-8")
    end

    private def stylesheet(body : String) : Caramel::Response
      ok(body, "text/css; charset=utf-8")
    end

    # Latte's owner token or the browser's development session may read the status.
    private def status(request : HTTP::Request) : Caramel::Response
      if token = request.headers["X-Caramel-Owner-Token"]?
        if token.bytesize == @owner_token.bytesize &&
           Crypto::Subtle.constant_time_compare(token, @owner_token)
          return status_response
        end
      end
      return refused unless session_request?(request)

      status_response
    end

    # True for a request from the page this session served: its cookie, the
    # `X-Caramel-Dev` header and, when sent, this project's origin.
    private def session_request?(request : HTTP::Request) : Bool
      cookie = request.cookies[COOKIE]?.try(&.value)
      origin = request.headers["Origin"]?
      return false unless cookie && cookie.bytesize == @token.bytesize

      Crypto::Subtle.constant_time_compare(cookie, @token) &&
        request.headers["X-Caramel-Dev"]? == "1" &&
        (origin.nil? || origin == @origin)
    end

    private def refused : Caramel::Response
      secure(Caramel::Response.new(403, "Refresh requires this project's development session"))
    end

    private def ok(body : String, content_type : String) : Caramel::Response
      headers = HTTP::Headers{"Content-Type" => content_type}
      secure(Caramel::Response.new(200, body, headers))
    end

    # The generation, state, newest trace and error tally that the refresh script and
    # Latte poll for.
    private def status_response : Caramel::Response
      latest = @events.try(&.latest) || 0_i64
      status = {
        generation: @generation,
        state:      @state,
        latest:     latest,
        errors:     @events.try(&.errors_seen) || 0,
        last_error: @events.try(&.last_error).try { |error| newest(error) },
      }
      ok(status.to_json, "application/json")
    end

    # What Latte shows of an error: no message, a bounded location.
    private def newest(error : Crema::ErrorEvent)
      {
        fingerprint: error.fingerprint,
        error_class: error.error_class.byte_slice(0, 200).scrub,
        location:    error.location.try(&.byte_slice(0, 200).scrub),
        at:          error.at,
      }
    end

    # The traces a page's toolbar and the inspector list ask for.
    private def traces_feed(request : HTTP::Request) : Caramel::Response
      return refused unless session_request?(request)

      empty = {latest: 0, traces: [] of Int32}.to_json
      inspector = @inspector || return ok(empty, "application/json")
      ok(inspector.feed(request), "application/json")
    end

    private def inspector_page(request : HTTP::Request) : Caramel::Response
      inspector = @inspector || return secure(Caramel::Response.new(404, "Not found"))
      page = inspector.response(request)
      secured = secure(page)
      return secured unless page.headers["Content-Type"]?.try(&.starts_with?("text/html"))

      body = with_script(page.body, @generation, nil)
      response = Caramel::Response.new(page.status, body, page.headers)
      add_cookie(response)
      secure(response)
    end

    private def diagnostic(request : HTTP::Request,
                           generation : Int64 = @generation) : Caramel::Response
      title = if @state == "building"
                "Building your application"
              else
                "Your application needs attention"
              end
      body = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">" \
             "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" \
             "<title>#{title} · Frappé</title>" \
             "<link rel=\"stylesheet\" href=\"/__caramel/dev/style.css\"></head>" \
             "<body><main><p>FRAPPÉ DEVELOPMENT</p><h1>#{title}</h1>" \
             "#{diagnostic_details}" \
             "<p>Save your changes to rebuild. " \
             "This page refreshes when the application is ready.</p></main>" \
             "#{script(generation, nil)}</body></html>"
      headers = HTTP::Headers{"Content-Type" => "text/html; charset=utf-8"}
      response = secure(Caramel::Response.new(503, body, headers))
      add_cookie(response)
      response
    end

    # The message alone, or the diagnostics as links with the compiler's output after them.
    private def diagnostic_details : String
      raw = "<pre>#{Caramel::HTML.escape(@message)}</pre>"
      return raw if @diagnostics.empty?

      articles = @diagnostics.join { |entry| article(entry) }
      "#{articles}<details><summary>Compiler output</summary>#{raw}</details>"
    end

    private def article(entry : Diagnostic) : String
      text = Caramel::HTML.escape(redact(entry.message))
      source = entry.source.try { |lines| "<pre>#{Caramel::HTML.escape(redact(lines))}</pre>" }
      fix = entry.remediation.try { |remedy| "<p>#{Caramel::HTML.escape(remedy)}</p>" }
      "<article class=\"diagnostic\">#{location_link(entry)}<p>#{text}</p>#{source}#{fix}</article>"
    end

    private def location_link(entry : Diagnostic) : String
      label = Caramel::HTML.escape(entry.location)
      path = File.join(@root || "", entry.file)
      path = entry.file if entry.file.starts_with?("/")
      href = @editor.link(path, entry.line, entry.column)
      href.empty? ? "<p>#{label}</p>" : "<a href=\"#{Caramel::HTML.escape(href)}\">#{label}</a>"
    end

    # Forwards one request to the ready application over a fresh Unix socket.
    #
    # Buffered responses (everything except event streams) are read whole
    # under a 30-second read timeout; full HTML gets the refresh script.
    # HEAD answers and 1xx, 204 and 304 statuses have no body, so none is
    # read or decorated.
    #
    # A non-HEAD response whose Content-Type starts with `text/event-stream`
    # is returned as a streaming `Caramel::Response` instead: bytes are copied
    # to the browser and flushed as they arrive, with no refresh script and no
    # read timeout, so an idle stream stays open indefinitely. The upstream
    # exchange therefore runs in its own fiber, which owns the socket and
    # closes it when the copy ends (the app finished, the app process exited,
    # or the browser disconnected) or 30 seconds after handoff if the
    # response is never consumed. Open streams are not tied to the refresh
    # generation: they stay on the process that accepted them.
    # ameba:disable Metrics/CyclomaticComplexity -- the proxy's streaming and failure paths
    private def forward(request : HTTP::Request,
                        path : String,
                        generation : Int64) : Caramel::Response
      # ameba:disable Lint/UselessAssign -- read by the ensure below when forwarding fails early
      spawned = false
      socket = Socket.unix
      socket.connect(Socket::UNIXAddress.new(path), timeout: 1.second)
      socket.read_timeout = 30.seconds
      socket.write_timeout = 30.seconds
      client = HTTP::Client.new(socket, @authority)
      headers = request.headers.dup
      remove_hop_headers(headers)
      headers["Accept-Encoding"] = "identity"
      headers["Connection"] = "close"
      outcome = Channel(Caramel::Response | Exception).new(1)
      started = Channel(Nil).new(1)
      released = Channel(Nil).new(1)
      spawned = true
      spawn do
        client.exec(request.method, request.resource, headers, request.body) do |upstream|
          returned = upstream.headers.dup
          remove_hop_headers(returned)
          # A HEAD answer keeps the upstream's length: it describes the app's
          # page, before the development script a GET would add.
          returned.delete("Content-Length") unless request.method == "HEAD"
          returned["Cache-Control"] = "no-store"
          if bodiless?(request, upstream.status_code)
            # HEAD, 1xx, 204 and 304 carry no body to read or decorate.
            response = Caramel::Response.new(upstream.status_code, "", returned)
            add_cookie(response)
            outcome.send(response)
          elsif returned["Content-Type"]?.try(&.starts_with?("text/event-stream"))
            socket.read_timeout = nil
            body_io = upstream.body_io
            response = Caramel::Response.stream(upstream.status_code, returned) do |io|
              started.send(nil)
              buffer = Bytes.new(4096)
              while (count = body_io.read(buffer)) > 0
                io.write(buffer[0, count])
                io.flush
              end
            ensure
              released.send(nil)
            end
            add_cookie(response)
            outcome.send(response)
            select
            when started.receive
              released.receive
            when timeout(30.seconds)
            end
            # An unfinished event stream never ends; closing stops the
            # client from draining it after this block.
            socket.close
          else
            body = upstream.body_io?.try(&.gets_to_end) || ""
            if full_page?(request, returned)
              body = with_script(body, generation, returned["X-Request-ID"]?)
              returned.delete("ETag")
              returned["Cache-Control"] = "no-store"
            end
            response = Caramel::Response.new(upstream.status_code, body, returned)
            add_cookie(response)
            outcome.send(response)
          end
        end
      rescue error
        # Buffered: after a stream was handed off nobody receives this.
        outcome.send(error)
      ensure
        client.close
        socket.close
      end
      result = outcome.receive
      raise result if result.is_a?(Exception)
      result
    rescue IO::Error
      if generation == @generation && @state == "ready"
        failed("The application stopped responding. Check the terminal output; " \
               "Frappé will retry after your next source change.")
        diagnostic(request)
      else
        diagnostic(request, generation)
      end
    ensure
      socket.try(&.close) unless spawned
    end

    private def bodiless?(request : HTTP::Request, status : Int32) : Bool
      request.method == "HEAD" || status < 200 || status == 204 || status == 304
    end

    # A whole, uncompressed HTML page, which gets the refresh script.
    private def full_page?(request : HTTP::Request, headers : HTTP::Headers) : Bool
      return false unless headers["Content-Type"]?.try(&.starts_with?("text/html"))
      return false if headers.has_key?("Content-Encoding")
      request.headers["HX-Request-Type"]? != "partial"
    end

    # *body* with the refresh script before its `</body>`, or at its end. A page
    # that came from a traced request also names it, so the toolbar can show it.
    private def with_script(body : String, generation : Int64, request_id : String?) : String
      tag = script(generation, request_id)
      return body + tag unless body.includes?("</body>")
      body.sub("</body>", tag + "</body>")
    end

    private def script(generation : Int64, request_id : String?) : String
      request = request_id.try { |id| " data-request=\"#{Caramel::HTML.escape(id)}\"" }
      "<script src=\"/__caramel/dev/client.js\" data-generation=\"#{generation}\"#{request} " \
      "defer></script>"
    end

    private def add_cookie(response : Caramel::Response) : Nil
      cookie = HTTP::Cookie.new(COOKIE, @token,
        path: "/",
        secure: true,
        http_only: true,
        samesite: HTTP::Cookie::SameSite::Strict)
      response.headers.add("Set-Cookie", cookie.to_set_cookie_header)
    end

    private def secure(response : Caramel::Response) : Caramel::Response
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Security-Policy"] = CONTENT_SECURITY_POLICY
      response.headers["Referrer-Policy"] = "same-origin"
      response
    end

    private def redact(message : String) : String
      Caramel::Crema::Redact.text(message, @secrets, 32_768, credentials: false)
    end

    private def remove_hop_headers(headers : HTTP::Headers) : Nil
      headers["Connection"]?.try(&.split(',').each { |name| headers.delete(name.strip) })
      HOP_HEADERS.each { |name| headers.delete(name) }
    end
  end
end
