require "uri"
require "./response"

module Caramel
  class Router
    alias Handler = Proc(HTTP::Request, Hash(String, String), Response)
    private record Route, method : String, segments : Array(String), handler : Handler
    @routes = [] of Route

    def add(method : String, path : String, &handler : HTTP::Request, Hash(String, String) -> Response) : self
      raise ArgumentError.new("route requires an absolute path") unless path.starts_with?("/")
      @routes << Route.new(method.upcase, path.split('/'), handler)
      self
    end

    {% for method in %w(get post put patch delete) %}
      def {{method.id}}(path : String, &handler : HTTP::Request, Hash(String, String) -> Response) : self
        add({{method.upcase}}, path, &handler)
      end
    {% end %}

    def call(request : HTTP::Request) : Response
      path = request.path
      return Response.new(400, "Malformed path") unless path.starts_with?("/")
      return Response.new(400, "Malformed path") if path.matches?(/%(?![0-9a-fA-F]{2})/)
      segments = path.split('/').map { |segment| URI.decode(segment) }
      return Response.new(400, "Malformed path") if segments.any? { |segment| segment.includes?('/') || segment.includes?('\\') || segment.each_char.any? { |char| char.ord < 32 || char.ord == 127 } || !segment.valid_encoding? }
      allowed = [] of String
      @routes.each do |route|
        next unless route.segments.size == segments.size
        params = {} of String => String
        matched = route.segments.zip(segments).all? do |expected, actual|
          if expected.starts_with?(':')
            params[expected[1..]] = actual
            !actual.empty?
          else
            expected == actual
          end
        end
        next unless matched
        allowed << route.method
        allowed << "HEAD" if route.method == "GET"
        next unless route.method == request.method || (request.method == "HEAD" && route.method == "GET")
        response = route.handler.call(request, params)
        if request.method == "HEAD"
          headers = response.headers.dup
          headers["Content-Length"] = response.body.bytesize.to_s
          return Response.new(response.status, "", headers)
        end
        return response
      end
      return Response.new(404, "Not found") if allowed.empty?
      Response.new(405, "Method not allowed", HTTP::Headers{"Allow" => allowed.uniq.join(", ")})
    end
  end
end
