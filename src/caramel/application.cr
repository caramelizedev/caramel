require "http/server"
require "mime"
require "uuid"
require "log"
require "./router"
require "./form"
require "./csrf"
{% if flag?(:caramel_development) %}
  require "./development_error"
{% end %}

module Caramel
  class Forbidden < Exception; end

  # The HTTP server is a private upstream behind the trusted local proxy. Host
  # validation uses the configured origin; forwarded headers grant no trust.
  class Application
    include HTTP::Handler
    @authority : String
    @public_root : String?

    def initialize(@router : Router, origin : String, public_root : String? = nil)
      uri = URI.parse(origin)
      unless uri.scheme == "https" && uri.host && uri.path.empty? && uri.user.nil? && uri.password.nil? && uri.query.nil? && uri.fragment.nil?
        raise ArgumentError.new("Application origin must be an HTTPS origin")
      end
      @authority = uri.authority.not_nil!
      @public_root = public_root.try { |root| File.realpath(root) }
    end

    def handle(request : HTTP::Request) : Response
      return secure(Response.new(400, "Malformed path")) unless request.path.starts_with?("/")
      response = if request.headers["Host"]? != @authority
                   Response.new(421, "Unknown project host")
                 else
                   static_response(request) || @router.call(request)
                 end
      secure(response)
    rescue Forbidden
      secure(Response.new(403, "This form has expired or came from another site. Reload the page and try again."))
    rescue Form::TooLarge
      secure(Response.new(413, "Form is too large"))
    rescue Form::UnsupportedMediaType
      secure(Response.new(415, "Expected a URL-encoded form"))
    rescue Form::InvalidEncoding
      secure(Response.new(400, "Malformed form"))
    rescue error
      request_id = UUID.random.to_s
      # Do not log arbitrary exception messages: dependency errors may include
      # connection URLs, form values, or other secrets.
      Log.error { "request_id=#{request_id} error_type=#{error.class}" }
      {% if flag?(:caramel_development) %}
        if ENV["CARAMEL_ENV"]? == "development"
          return secure(DevelopmentError.response(error, request_id, request))
        end
      {% end %}
      headers = HTTP::Headers{"X-Request-ID" => request_id, "Cache-Control" => "no-store", "Content-Type" => "text/plain; charset=utf-8"}
      secure(Response.new(500, "Something went wrong. Reference: #{request_id}", headers))
    end

    def call(context : HTTP::Server::Context) : Nil
      response = handle(context.request)
      context.response.status_code = response.status
      response.headers.each { |name, values| context.response.headers[name] = values }
      context.response.print(response.body)
    end

    private def secure(response : Response) : Response
      response.headers["X-Content-Type-Options"] = "nosniff"
      response.headers["Referrer-Policy"] = "same-origin"
      response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'"
      response
    end

    private def static_response(request : HTTP::Request) : Response?
      root = @public_root
      return unless root
      path = request.path
      return Response.new(400, "Malformed path") if path.matches?(/%(?![0-9a-fA-F]{2})/)
      decoded = URI.decode(path)
      return Response.new(404, "Not found") if decoded.includes?('\0') || decoded.includes?('\\') || decoded.split('/').any? { |segment| segment.starts_with?('.') }
      candidate = File.expand_path(".#{decoded}", root)
      return unless candidate.starts_with?(root + "/") && File.file?(candidate)
      real = File.realpath(candidate)
      return Response.new(404, "Not found") unless real.starts_with?(root + "/")
      unless {"GET", "HEAD"}.includes?(request.method)
        return Response.new(405, "Method not allowed", HTTP::Headers{"Allow" => "GET, HEAD"})
      end
      headers = HTTP::Headers{"Content-Type" => MIME.from_filename(real, "application/octet-stream"), "Content-Length" => File.size(real).to_s}
      Response.new(200, request.method == "HEAD" ? "" : File.read(real), headers)
    end
  end
end
