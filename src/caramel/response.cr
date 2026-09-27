require "http"

module Caramel
  # An application response, independent of its server transport.
  struct Response
    alias Streamer = Proc(IO, Nil)

    getter status : Int32
    getter body : String
    getter headers : HTTP::Headers
    # Writes the body directly to the transport when set; `body` is then empty.
    getter streamer : Streamer?

    def initialize(@status = 200, @body = "", @headers = HTTP::Headers.new, @streamer : Streamer? = nil)
    end

    def self.stream(status : Int32 = 200, headers : HTTP::Headers = HTTP::Headers.new, &block : IO -> Nil) : self
      new(status, "", headers, block)
    end

    def self.html(request : HTTP::Request, *, full : String, partial : String, status = 200) : self
      body = request.headers["HX-Request-Type"]? == "partial" ? partial : full
      new(status, body, HTTP::Headers{"Content-Type" => "text/html; charset=utf-8", "Vary" => "HX-Request-Type"})
    end

    def self.redirect(path : String, status = 303) : self
      unless path.starts_with?("/") && !path.starts_with?("//") && !path.includes?('\\') && !path.each_char.any? { |char| char.ord < 32 || char.ord == 127 }
        raise ArgumentError.new("redirect requires a local absolute path")
      end
      new(status, "", HTTP::Headers{"Location" => path})
    end

    def self.navigate(request : HTTP::Request, path : String) : self
      response = redirect(path)
      response.headers["Vary"] = "HX-Request"
      response.headers["Cache-Control"] = "no-store"
      if request.headers["HX-Request"]? == "true"
        new(200, "", HTTP::Headers{"HX-Location" => path, "Vary" => "HX-Request", "Cache-Control" => "no-store"})
      else
        response
      end
    end
  end
end
