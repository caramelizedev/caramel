require "http/client"
require "random/secure"
require "socket"
require "uri"
require "./crema"
require "./external_url"
require "./tls"
require "./outbound/address"

module Caramel
  # The framework's outbound HTTP client for third-party APIs. It connects
  # directly unless `proxy` ("host:port") is set; then every request goes to
  # that socket in HTTP/1.1 absolute form (`GET https://api.stripe.com/v1/customers HTTP/1.1`).
  # Corretto points it at its wire-fake proxy for the whole spec suite.
  #
  # A direct call resolves the host first and refuses, with `Blocked`, any
  # address that is loopback, private, link-local, multicast or reserved, then
  # connects to the vetted address itself, so a user-supplied URL cannot reach the
  # host's own network and a DNS answer cannot change between the check and the
  # connection. `allow_private = true` turns the check off; a proxy skips it,
  # because the proxy resolves the host. Every call, direct or through the proxy,
  # reads at most `max_response_bytes` (`TooLarge` past it) and finishes within
  # `deadline` (`IO::TimeoutError` past it).
  #
  # Inside a Crema trace each call is a timed span, and a `traceparent` header
  # carries the trace to the service unless the caller already set one.
  module Outbound
    CONNECT_TIMEOUT    = 5.seconds
    READ_TIMEOUT       = 30.seconds
    DEADLINE           = 60.seconds
    MAX_RESPONSE_BYTES = 10 * 1024 * 1024

    class_property proxy : String? = nil
    class_property? allow_private : Bool = false
    class_property deadline : Time::Span = DEADLINE
    class_property max_response_bytes : Int32 = MAX_RESPONSE_BYTES

    # The host resolves to an address `direct` refuses; the message names the host
    # and the address class, never the URL.
    class Blocked < Exception
    end

    # The response body passed `max_response_bytes`; the connection is closed.
    class TooLarge < Exception
    end

    def self.request(method : String,
                     url : String,
                     headers : HTTP::Headers = HTTP::Headers.new,
                     body : String? = nil) : HTTP::Client::Response
      unless ExternalURL.valid?(url)
        raise ArgumentError.new("Outbound requests need an absolute http(s) URL " \
                                "without credentials or whitespace: #{url.inspect}")
      end
      uri = URI.parse(url)
      unless method.matches?(/\A[A-Z]{1,16}\z/)
        raise ArgumentError.new("Unsupported HTTP method: #{method.inspect}")
      end
      name = "#{method} #{uri.host}"
      Crema.measure(Crema::SpanKind::Http, name, span_detail(uri)) do |span|
        sent = propagated(headers)
        response = if proxy = @@proxy
                     through(proxy, method, url, uri, sent, body)
                   else
                     direct(method, uri, sent, body)
                   end
        span.try(&.status = response.status_code)
        response
      end
    end

    {% if flag?(:caramel_development) %}
      # Development spans name the path too; production keeps scheme and host only.
      private def self.span_detail(uri : URI) : String
        return "#{uri.scheme}://#{uri.host}" unless Crema.development?

        "#{uri.scheme}://#{uri.host}#{uri.path}"
      end
    {% else %}
      private def self.span_detail(uri : URI) : String
        "#{uri.scheme}://#{uri.host}"
      end
    {% end %}

    def self.get(url : String,
                 headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
      request("GET", url, headers)
    end

    def self.post(url : String,
                  headers : HTTP::Headers = HTTP::Headers.new,
                  body : String? = nil) : HTTP::Client::Response
      request("POST", url, headers, body)
    end

    # *headers* with the current trace's `traceparent`, unless it has one.
    private def self.propagated(headers : HTTP::Headers) : HTTP::Headers
      trace = Crema.current? || return headers
      return headers if headers.has_key?("traceparent")

      sent = headers.dup
      sent["traceparent"] = Crema::Ids.traceparent(trace.trace_id, Random::Secure.hex(8),
        trace.sampled?)
      sent
    end

    private def self.direct(method : String,
                            uri : URI,
                            headers : HTTP::Headers,
                            body : String?) : HTTP::Client::Response
      host = uri.host.as(String)
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      tcp = connected(host, port)
      tcp.read_timeout = READ_TIMEOUT
      tcp.write_timeout = READ_TIMEOUT
      io = secured(tcp, uri)
      begin
        sent = headers.dup
        sent["Host"] = host_header(uri)
        sent["Connection"] = "close"
        sent["User-Agent"] ||= "Crystal"
        sent["Accept-Encoding"] ||= "identity"
        bounded(tcp, host) do
          HTTP::Request.new(method, uri.request_target, sent, body).to_io(io)
          io.flush
          answer(io, tcp, host, method)
        end
      ensure
        closed(io)
      end
    end

    # A TCP connection to *host*: to the first vetted address that accepts it, or
    # resolved by the socket itself when `allow_private` is set.
    private def self.connected(host : String, port : Int32) : TCPSocket
      if @@allow_private
        return TCPSocket.new(host, port, dns_timeout: CONNECT_TIMEOUT,
          connect_timeout: CONNECT_TIMEOUT)
      end
      addresses = Socket::Addrinfo.tcp(host, port, timeout: CONNECT_TIMEOUT).map(&.ip_address)
      addresses.each do |ip|
        kind = address_class(ip) || next
        raise Blocked.new("Outbound refuses #{host}: it resolves to a #{kind} address")
      end
      refused = nil
      addresses.each do |ip|
        return TCPSocket.new(ip.address, port, connect_timeout: CONNECT_TIMEOUT)
      rescue error : Socket::ConnectError
        refused = error
      end
      raise(refused || Socket::ConnectError.new("No address found for #{host}"))
    end

    # *tcp* wrapped in TLS for an https *uri*, verifying the certificate against the
    # host name, which also goes out as SNI; the plain socket for http.
    private def self.secured(tcp : TCPSocket, uri : URI) : IO
      context = TLS.client_context(uri) || return tcp
      OpenSSL::SSL::Socket::Client.new(tcp, context: context, sync_close: true,
        hostname: uri.host)
    rescue error
      tcp.close
      raise error
    end

    # Closes *io*; a TLS socket whose connection the cap or the deadline already
    # closed cannot send `close_notify`, which is no error here.
    private def self.closed(io : IO) : Nil
      io.close
    rescue IO::Error | OpenSSL::Error
    end

    private def self.host_header(uri : URI) : String
      host = uri.host.as(String)
      host = "[#{host}]" if host.includes?(':')
      port = uri.port || return host

      "#{host}:#{port}"
    end

    # Yields, and closes *tcp* from a fiber once `deadline` passes without the block
    # finishing, so that a server that stalls cannot hold the call open.
    private def self.bounded(tcp : TCPSocket, host : String, &)
      finished = false
      expired = false
      spawn do
        sleep @@deadline
        next if finished || tcp.closed?
        expired = true
        tcp.close
      rescue IO::Error
      end
      begin
        yield
      rescue error : IO::Error | OpenSSL::Error
        raise error unless expired

        seconds = @@deadline.total_seconds
        raise IO::TimeoutError.new("Outbound call to #{host} did not finish " \
                                   "within #{seconds} seconds")
      ensure
        finished = true
      end
    end

    # The response on *io*, its body read through the cap into a string; *tcp* is
    # the connection to close past the cap.
    private def self.answer(io : IO,
                            tcp : TCPSocket,
                            host : String,
                            method : String) : HTTP::Client::Response
      head = method == "HEAD"
      parsed = HTTP::Client::Response.from_io(io, ignore_body: head,
        decompress: false) do |response|
        content = response.body_io?
        body = content ? capped(content, tcp, host) : nil
        HTTP::Client::Response.new(response.status, body, response.headers,
          response.status_message, response.version)
      end
      parsed || raise IO::EOFError.new("Unexpected end of http response")
    end

    private def self.capped(content : IO, tcp : TCPSocket, host : String) : String
      limit = @@max_response_bytes
      buffer = uninitialized UInt8[8192]
      total = 0
      String.build do |text|
        while (count = content.read(buffer.to_slice)) > 0
          total += count
          if total > limit
            tcp.close
            raise TooLarge.new("Outbound response from #{host} exceeds #{limit} bytes")
          end
          text.write(buffer.to_slice[0, count])
        end
      end
    end

    private def self.through(proxy : String,
                             method : String,
                             url : String,
                             uri : URI,
                             headers : HTTP::Headers,
                             body : String?) : HTTP::Client::Response
      host, _, port = proxy.rpartition(':')
      target = uri.host.as(String)
      socket = TCPSocket.new(host, port.to_i, connect_timeout: CONNECT_TIMEOUT)
      socket.read_timeout = READ_TIMEOUT
      socket.write_timeout = READ_TIMEOUT
      begin
        sent = headers.dup
        sent["Host"] = host_header(uri)
        sent["Connection"] = "close"
        sent["Accept-Encoding"] ||= "identity"
        sent["Content-Length"] = body.bytesize.to_s if body
        bounded(socket, target) do
          socket << method << ' ' << url << " HTTP/1.1\r\n"
          sent.each do |name, values|
            values.each { |value| socket << name << ": " << value << "\r\n" }
          end
          socket << "\r\n"
          socket << body if body
          socket.flush
          answer(socket, socket, target, method)
        end
      ensure
        socket.close
      end
    end
  end
end
