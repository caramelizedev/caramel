require "uri"
require "./response"
require "./csrf"

module Caramel
  class Router
    alias Handler = Proc(HTTP::Request, Hash(String, String), Response)
    private record Route, method : String, segments : Array(String), handler : Handler
    @routes = [] of Route

    def routes : Array(Tuple(String, String))
      @routes.map { |route| {route.method, route.segments.join('/')} }
    end

    # Direct calls keep every controller binding subject to Crystal's type
    # checker. The extra POST member route supports native HTML method forms;
    # its controller change action must check CSRF before dispatching a change.
    def resources(name : Symbol, controller : T.class, csrf : CSRF) : self forall T
      plural = name.to_s
      raise ArgumentError.new("resource name must be a lowercase identifier") unless plural.matches?(/\A[a-z][a-z0-9_]*\z/)
      base = "/#{plural}"
      get(base) { |request, _| T.new(request, csrf).index }
      get("#{base}/new") { |request, _| T.new(request, csrf).new }
      post(base) { |request, _| T.new(request, csrf).create }
      {% for route in { {"get", "", "show"}, {"get", "/edit", "edit"}, {"patch", "", "update"}, {"put", "", "update"}, {"delete", "", "destroy"}, {"post", "", "change"} } %}
        {{route[0].id}}("#{base}/:id" + {{route[1]}}) do |request, params|
          raw = params["id"]
          id = raw.matches?(/\A[0-9]+\z/) ? raw.to_i64? : nil
          if id && id > 0
            T.new(request, csrf).{{route[2].id}}(id)
          else
            Response.new(404, "Not found")
          end
        end
      {% end %}
      self
    end

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

  # Include generated paths in the application's controller base. IDs are
  # explicit Int64 values; an unsaved record must be checked before linking it.
  macro resource_paths(plural, singular)
    {% plural_name = plural.id.stringify %}
    {% singular_name = singular.id.stringify %}
    {% unless plural_name =~ /^[a-z][a-z0-9_]*$/ && singular_name =~ /^[a-z][a-z0-9_]*$/ %}
      {% raise "resource path names must be lowercase identifiers" %}
    {% end %}
    def {{plural.id}}_path : String
      {{"/#{plural.id}"}}
    end

    def {{singular.id}}_path(id : Int64) : String
      raise ArgumentError.new("record ID must be positive") unless id > 0
      {{"/#{plural.id}/"}} + id.to_s
    end

    def new_{{singular.id}}_path : String
      {{"/#{plural.id}/new"}}
    end

    def edit_{{singular.id}}_path(id : Int64) : String
      {{singular.id}}_path(id) + "/edit"
    end
  end
end
