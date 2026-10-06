require "http/client"
require "random/secure"
require "socket"
require "uri"
require "./crema"
require "./external_url"

module Caramel
  # The framework's outbound HTTP client for third-party APIs. It connects
  # directly unless `proxy` ("host:port") is set; then every request goes to
  # that socket in HTTP/1.1 absolute form (`GET https://api.stripe.com/v1/customers HTTP/1.1`).
  # Corretto points it at its wire-fake proxy for the whole spec suite.
  #
  # Inside a Crema trace each call is a timed span, and a `traceparent` header
  # carries the trace to the service unless the caller already set one.
  module Outbound
    CONNECT_TIMEOUT = 5.seconds
    READ_TIMEOUT    = 30.seconds

    class_property proxy : String? = nil

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
      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      begin
        client.exec(method, uri.request_target, headers, body)
      ensure
        client.close
      end
    end

    private def self.through(proxy : String,
                             method : String,
                             url : String,
                             uri : URI,
                             headers : HTTP::Headers,
                             body : String?) : HTTP::Client::Response
      host, _, port = proxy.rpartition(':')
      socket = TCPSocket.new(host, port.to_i, connect_timeout: CONNECT_TIMEOUT)
      socket.read_timeout = READ_TIMEOUT
      begin
        sent = headers.dup
        unless target = uri.host
          raise ArgumentError.new("Outbound requests need an absolute URL: #{url}")
        end
        sent["Host"] = uri.port ? "#{target}:#{uri.port}" : target
        sent["Connection"] = "close"
        sent["Content-Length"] = body.bytesize.to_s if body
        socket << method << ' ' << url << " HTTP/1.1\r\n"
        sent.each do |name, values|
          values.each { |value| socket << name << ": " << value << "\r\n" }
        end
        socket << "\r\n"
        socket << body if body
        socket.flush
        HTTP::Client::Response.from_io(socket)
      ensure
        socket.close
      end
    end
  end
end
