require "http"
require "http/client/response"
require "mime"
require "socket"
require "../outbound"

module Corretto
  # The suite's wire-level fake for third-party HTTP: a local proxy that reads
  # the real bytes `Caramel::Outbound` sends, records each request and answers
  # from the matching stub. Unmatched requests get 502, so specs never reach
  # the network.
  class Wire
    FIXTURES = "spec/fixtures/wire"
    STUB_URL = "stub_wire takes the absolute URL the application requests, " \
               "such as https://api.stripe.com/v1/customers"

    record Request, method : String, url : String, headers : HTTP::Headers, body : String

    class Stub
      getter url : String
      getter method : String?
      getter status = 200
      getter headers = HTTP::Headers.new
      getter body = ""

      def initialize(@url : String, @method : String?)
      end

      # `fixture` names a file under spec/fixtures/wire/; its extension sets
      # the default Content-Type.
      def to_return(*,
                    status : Int32 = 200,
                    fixture : String? = nil,
                    body : String? = nil,
                    headers : Hash(String, String) = {} of String => String) : self
        raise ArgumentError.new("to_return takes fixture: or body:, not both") if fixture && body
        @status = status
        @headers = HTTP::Headers.new
        headers.each { |name, value| @headers[name] = value }
        if fixture
          @body = Wire.fixture(fixture)
          @headers["Content-Type"] ||= MIME.from_filename(fixture, "application/octet-stream")
        else
          @body = body || ""
        end
        self
      end

      def matches?(request : Request) : Bool
        @url == request.url && (@method.nil? || @method == request.method)
      end
    end

    getter address : String
    getter requests = [] of Request

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @address = "127.0.0.1:#{@server.local_address.port}"
      @stubs = [] of Stub
      spawn(name: "corretto-wire") { accept }
    end

    # Registers a stub for `url`; `method` nil matches any method. The latest
    # matching stub answers.
    def stub(url : String, method : String? = nil) : Stub
      unless url.starts_with?("http://") || url.starts_with?("https://")
        raise ArgumentError.new(STUB_URL)
      end
      Stub.new(url, method.try(&.upcase)).tap { |stub| @stubs << stub }
    end

    def reset : Nil
      @stubs.clear
      @requests.clear
    end

    def close : Nil
      @server.close
    end

    def self.fixture(name : String) : String
      if name.starts_with?('/') || name.split('/').any?(&.in?("", ".", ".."))
        raise ArgumentError.new("Wire fixtures are relative paths under #{FIXTURES}/: " \
                                "#{name.inspect}")
      end
      path = File.join(FIXTURES, name)
      unless File.file?(path)
        raise Error.new("Wire fixture #{path} does not exist; " \
                        "record the third party's response there.")
      end
      File.read(path)
    end

    # Reads one request (absolute-form for proxied requests) from real bytes;
    # nil at end of input or when the bytes are not an HTTP/1.1 request.
    def self.read(io : IO) : Request?
      request = HTTP::Request.from_io(io)
      return unless request.is_a?(HTTP::Request)
      Request.new(
        method: request.method,
        url: request.resource,
        headers: request.headers,
        body: request.body.try(&.gets_to_end) || "",
      )
    end

    # Records `request` and returns the response the proxy sends for it.
    def answer(request : Request) : HTTP::Client::Response
      @requests << request
      if stub = @stubs.reverse_each.find(&.matches?(request))
        HTTP::Client::Response.new(stub.status, stub.body, stub.headers.dup)
      else
        body = "Unstubbed outbound request: #{request.method} #{request.url}"
        headers = HTTP::Headers{"Content-Type" => "text/plain; charset=utf-8"}
        HTTP::Client::Response.new(502, body, headers)
      end
    end

    private def accept : Nil
      while socket = @server.accept?
        spawn serve(socket)
      end
    end

    private def serve(socket : TCPSocket) : Nil
      socket.read_timeout = 5.seconds
      if request = Wire.read(socket)
        response = answer(request)
        response.headers["Connection"] = "close"
        response.to_io(socket)
        socket.flush
      else
        body = "Corretto's wire proxy expects one HTTP/1.1 request"
        headers = HTTP::Headers{"Connection" => "close"}
        HTTP::Client::Response.new(400, body, headers).to_io(socket)
      end
    rescue IO::Error
    ensure
      socket.close
    end
  end
end
