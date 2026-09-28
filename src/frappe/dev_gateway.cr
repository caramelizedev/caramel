require "http/server"
require "http/client"
require "socket/unix_socket"
require "crypto/subtle"
require "./project"
require "../caramel/html"
require "../caramel/response"

module Caramel::Frappe
  # One stable, private socket sits behind Latte's HTTPS proxy. Only ready
  # builds receive application traffic; diagnostics and refresh stay local.
  class DevGateway
    include HTTP::Handler
    COOKIE = "__Host-caramel_dev"
    CLIENT = {{ read_file("#{__DIR__}/dev_client.js") }}
    getter generation : Int64 = 0_i64
    getter owner_token : String = Random::Secure.hex(32)
    getter state : String = "building"
    @message = "Compiling your application…"
    @upstream : String? = nil
    @token = Random::Secure.hex(32)
    @authority : String

    def initialize(@origin : String, @secrets : Array(String) = [] of String)
      uri = URI.parse(@origin)
      raise Error.new("Development requires an HTTPS origin") unless uri.scheme == "https" && uri.host && uri.path.empty?
      @authority = uri.authority || raise Error.new("Development requires an HTTPS origin")
    end

    def building : Nil
      @state = "building"
      @message = "Compiling your application…"
    end

    def ready(socket : String) : Nil
      @upstream = socket
      @state = "ready"
      @generation += 1
    end

    def failed(message : String) : Nil
      safe_message = redact(message)
      return if @state == "failed" && @message == safe_message
      @state = "failed"
      @message = safe_message
      @generation += 1
    end

    def assets_changed : Nil
      @generation += 1
    end

    def handle(request : HTTP::Request) : Caramel::Response
      return secure(Caramel::Response.new(421, "Unknown project host")) unless request.headers["Host"]? == @authority
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
        rescue IO::Error
          # The browser closed the stream.
        end
      else
        context.response.print(response.body)
      end
    end

    # ameba:disable Metrics/CyclomaticComplexity -- one branch per development endpoint
    private def endpoint(request : HTTP::Request) : Caramel::Response
      return secure(Caramel::Response.new(405, "Method not allowed")) unless request.method == "GET"
      case request.path
      when "/__caramel/dev/client.js"
        secure(Caramel::Response.new(200, CLIENT, HTTP::Headers{"Content-Type" => "text/javascript; charset=utf-8"}))
      when "/__caramel/dev/style.css"
        css = "body{max-width:960px;margin:8vh auto;padding:24px;font:16px/1.6 system-ui;background:#faf8f3;color:#332d27}h1{font:44px Georgia}pre{white-space:pre-wrap;overflow-wrap:anywhere;padding:24px;background:#fff;border:1px solid #e5dfd4;border-radius:8px}p{color:#786f65}"
        secure(Caramel::Response.new(200, css, HTTP::Headers{"Content-Type" => "text/css; charset=utf-8"}))
      when "/__caramel/dev/status"
        if token = request.headers["X-Caramel-Owner-Token"]?
          if token.bytesize == @owner_token.bytesize && Crypto::Subtle.constant_time_compare(token, @owner_token)
            return secure(Caramel::Response.new(200, {generation: @generation, state: @state}.to_json, HTTP::Headers{"Content-Type" => "application/json"}))
          end
        end
        cookie = request.cookies[COOKIE]?.try(&.value)
        origin = request.headers["Origin"]?
        unless cookie && cookie.bytesize == @token.bytesize && Crypto::Subtle.constant_time_compare(cookie, @token) && request.headers["X-Caramel-Dev"]? == "1" && (origin.nil? || origin == @origin)
          return secure(Caramel::Response.new(403, "Refresh requires this project's development session"))
        end
        secure(Caramel::Response.new(200, {generation: @generation, state: @state}.to_json, HTTP::Headers{"Content-Type" => "application/json"}))
      else
        secure(Caramel::Response.new(404, "Not found"))
      end
    end

    private def diagnostic(request : HTTP::Request, generation : Int64 = @generation) : Caramel::Response
      title = @state == "building" ? "Building your application" : "Your application needs attention"
      body = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>#{title} · Frappé</title><link rel=\"stylesheet\" href=\"/__caramel/dev/style.css\"></head><body><main><p>FRAPPÉ DEVELOPMENT</p><h1>#{title}</h1><pre>#{Caramel::HTML.escape(@message)}</pre><p>Save your changes to rebuild. This page refreshes when the application is ready.</p></main>#{script(generation)}</body></html>"
      response = secure(Caramel::Response.new(503, body, HTTP::Headers{"Content-Type" => "text/html; charset=utf-8"}))
      add_cookie(response)
      response
    end

    # Forwards one request to the ready application over a fresh Unix socket.
    #
    # Buffered responses (everything except event streams) are read whole
    # under a 30-second read timeout; full HTML gets the refresh script.
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
    private def forward(request : HTTP::Request, path : String, generation : Int64) : Caramel::Response
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
          returned.delete("Content-Length")
          returned["Cache-Control"] = "no-store"
          if request.method != "HEAD" && returned["Content-Type"]?.try(&.starts_with?("text/event-stream"))
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
            body = upstream.body_io.gets_to_end
            if returned["Content-Type"]?.try(&.starts_with?("text/html")) && !returned.has_key?("Content-Encoding") && request.headers["HX-Request-Type"]? != "partial"
              body = body.includes?("</body>") ? body.sub("</body>", script(generation) + "</body>") : body + script(generation)
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
        failed("The application stopped responding. Check the terminal output; Frappé will retry after your next source change.")
        diagnostic(request)
      else
        diagnostic(request, generation)
      end
    ensure
      socket.try(&.close) unless spawned
    end

    private def script(generation : Int64) : String
      "<script src=\"/__caramel/dev/client.js\" data-generation=\"#{generation}\" defer></script>"
    end

    private def add_cookie(response : Caramel::Response) : Nil
      response.headers.add("Set-Cookie", HTTP::Cookie.new(COOKIE, @token, path: "/", secure: true, http_only: true, samesite: HTTP::Cookie::SameSite::Strict).to_set_cookie_header)
    end

    private def secure(response : Caramel::Response) : Caramel::Response
      response.headers["Cache-Control"] = "no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; base-uri 'none'; frame-ancestors 'none'; object-src 'none'"
      response.headers["Referrer-Policy"] = "same-origin"
      response
    end

    private def redact(message : String) : String
      result = message.scrub
      @secrets.reject(&.empty?).sort_by!(&.bytesize).reverse_each { |secret| result = result.gsub(secret, "[redacted]") }
      result = result.gsub(/postgres(?:ql)?:\/\/[^\s"'<>]+/, "[database URL redacted]")
      result.byte_slice(0, Math.min(result.bytesize, 32_768)).scrub
    end

    private def remove_hop_headers(headers : HTTP::Headers) : Nil
      headers["Connection"]?.try(&.split(',').each { |name| headers.delete(name.strip) })
      %w[Connection Keep-Alive Proxy-Authenticate Proxy-Authorization TE Trailer Transfer-Encoding Upgrade].each { |name| headers.delete(name) }
    end
  end
end
