require "http/client"
require "socket"
require "uri"

module Caramel
  # The framework's outbound HTTP client for third-party APIs. It connects
  # directly unless `proxy` ("host:port") is set; then every request goes to
  # that socket in HTTP/1.1 absolute form (`GET https://api.stripe.com/v1/customers HTTP/1.1`).
  # Corretto points it at its wire-fake proxy for the whole spec suite.
  module Outbound
    CONNECT_TIMEOUT = 5.seconds
    READ_TIMEOUT    = 30.seconds

    class_property proxy : String? = nil

    def self.request(method : String, url : String, headers : HTTP::Headers = HTTP::Headers.new, body : String? = nil) : HTTP::Client::Response
      uri = URI.parse(url)
      unless uri.scheme.in?("http", "https") && uri.host.presence && uri.user.nil? && url.each_char.none? { |char| char.ascii_whitespace? || char.ord < 32 || char.ord == 127 }
        raise ArgumentError.new("Outbound requests need an absolute http(s) URL without credentials or whitespace: #{url.inspect}")
      end
      raise ArgumentError.new("Unsupported HTTP method: #{method.inspect}") unless method.matches?(/\A[A-Z]{1,16}\z/)
      if proxy = @@proxy
        through(proxy, method, url, uri, headers, body)
      else
        client = HTTP::Client.new(uri)
        client.connect_timeout = CONNECT_TIMEOUT
        client.read_timeout = READ_TIMEOUT
        begin
          client.exec(method, uri.request_target, headers, body)
        ensure
          client.close
        end
      end
    end

    def self.get(url : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
      request("GET", url, headers)
    end

    def self.post(url : String, headers : HTTP::Headers = HTTP::Headers.new, body : String? = nil) : HTTP::Client::Response
      request("POST", url, headers, body)
    end

    private def self.through(proxy : String, method : String, url : String, uri : URI, headers : HTTP::Headers, body : String?) : HTTP::Client::Response
      host, _, port = proxy.rpartition(':')
      socket = TCPSocket.new(host, port.to_i, connect_timeout: CONNECT_TIMEOUT)
      socket.read_timeout = READ_TIMEOUT
      begin
        sent = headers.dup
        target = uri.host || raise ArgumentError.new("Outbound requests need an absolute URL: #{url}")
        sent["Host"] = uri.port ? "#{target}:#{uri.port}" : target
        sent["Connection"] = "close"
        sent["Content-Length"] = body.bytesize.to_s if body
        socket << method << ' ' << url << " HTTP/1.1\r\n"
        sent.each { |name, values| values.each { |value| socket << name << ": " << value << "\r\n" } }
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
