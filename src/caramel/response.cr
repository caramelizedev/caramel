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
      if !path.starts_with?("/") || path.starts_with?("//") || path.includes?('\\') || path.each_char.any? { |char| char.ord < 32 || char.ord == 127 }
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

    EXTERNAL_REDIRECT_STATUSES = {301, 302, 303, 307, 308}

    # Redirects to another site on purpose, such as a short link's destination.
    # Only absolute http and https URLs are accepted; `redirect` keeps refusing
    # them, so an external redirect is always explicit. htmx requests get
    # HX-Redirect, which makes the browser navigate instead of fetching.
    def self.redirect_external(request : HTTP::Request, url : String, status : Int32 = 302) : self
      raise ArgumentError.new("external redirect status must be 301, 302, 303, 307 or 308") unless EXTERNAL_REDIRECT_STATUSES.includes?(status)
      if url.each_char.any? { |char| char.ord < 32 || char.ord == 127 || char == '\\' }
        raise ArgumentError.new("external redirect requires an absolute http or https URL")
      end
      uri = begin
        URI.parse(url)
      rescue URI::Error
        raise ArgumentError.new("external redirect requires an absolute http or https URL")
      end
      if uri.host.to_s.empty? || !{"http", "https"}.includes?(uri.scheme)
        raise ArgumentError.new("external redirect requires an absolute http or https URL")
      end
      headers = HTTP::Headers{"Vary" => "HX-Request", "Cache-Control" => "no-store"}
      if request.headers["HX-Request"]? == "true"
        headers["HX-Redirect"] = url
        new(200, "", headers)
      else
        headers["Location"] = url
        new(status, "", headers)
      end
    end
  end
end
