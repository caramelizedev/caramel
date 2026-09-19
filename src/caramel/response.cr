require "http"

module Caramel
  # An application response, independent of its server transport.
  struct Response
    getter status : Int32
    getter body : String
    getter headers : HTTP::Headers

    def initialize(@status = 200, @body = "", @headers = HTTP::Headers.new)
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
  end
end
