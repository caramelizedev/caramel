require "http/server"
require "socket/unix_server"
require "json"
require "uuid"
require "./registry"
require "./control_api"
require "./state_format"
require "./deadline"
require "./project_status"
require "../caramel/response"

{% if flag?(:darwin) %}
  lib LibC
    fun getpeereid(fd : Int, uid : UidT*, gid : GidT*) : Int
  end
{% end %}

module Caramel::Latte
  # The daemon owns side effects; both Frappé and the menu app use this API.
  abstract class ServiceControl
    abstract def status_json(version : Int32) : String
    abstract def start_services : Nil
    abstract def stop_services : Nil
    abstract def register(name : String, directory : String, suffix : String) : Site
    abstract def unregister(id : String) : Bool
    abstract def set_upstream(id : String, socket : String) : Site

    def clear_upstream(id : String, socket : String) : Bool
      raise PublicError.new("unavailable", "Project cleanup is unavailable")
    end

    def environment_json(id : String, directory : String) : String
      raise PublicError.new("unavailable", "Project environment is unavailable")
    end

    def create_branch_json(id : String, name : String) : String
      raise PublicError.new("unavailable", "Database branching is unavailable")
    end

    def branches_json(id : String) : String
      raise PublicError.new("unavailable", "Database branching is unavailable")
    end

    def drop_branch(id : String, name : String) : Bool
      raise PublicError.new("unavailable", "Database branching is unavailable")
    end

    def test_worker_json(id : String, index : Int32) : String
      raise PublicError.new("unavailable", "Test worker databases are unavailable")
    end

    def drop_test_worker(id : String, index : Int32) : Bool
      raise PublicError.new("unavailable", "Test worker databases are unavailable")
    end

    def traces_json(limit : Int32) : String
      raise PublicError.new("unavailable", "The trace collector is unavailable")
    end

    def trace_json(trace_id : String) : String
      raise PublicError.new("unavailable", "The trace collector is unavailable")
    end
  end

  class PublicError < Exception
    getter code : String
    getter status : Int32

    def initialize(@code : String, message : String, @status : Int32 = 503)
      super(message)
    end
  end

  # Restricts accepted connections to the installing Unix user. A total
  # connection deadline also bounds trickled headers/bodies, independently of
  # the socket's inactivity timeout. IPC responses close the connection.
  class OwnerServer < UNIXServer
    def initialize(path : String, @idle_timeout : Time::Span)
      StateSecurity.validate_owned_directory(File.dirname(path))
      if File.info?(path, follow_symlinks: false)
        raise ArgumentError.new("Latte control socket already exists")
      end
      super(path)
      File.chmod(path, 0o600)
    end

    def accept? : UNIXSocket?
      while socket = super
        {% if flag?(:darwin) %}
          uid = 0_u32
          gid = 0_u32
          if LibC.getpeereid(socket.fd, pointerof(uid), pointerof(gid)) != 0 || uid != LibC.getuid
            socket.close
            next
          end
        {% end %}
        socket.read_timeout = @idle_timeout
        socket.write_timeout = @idle_timeout
        expire(socket)
        return socket
      end
      nil
    end

    private def expire(socket : UNIXSocket)
      spawn do
        sleep 15.seconds
        socket.close unless socket.closed?
      rescue IO::Error
      end
    end
  end

  # HTTP::Server's dispatch hook runs immediately after accept. Carry one budget
  # through header/body parsing and service work in the request's own fiber.
  class DeadlineServer < HTTP::Server
    def initialize(@request_deadline : Time::Span, &handler : HTTP::Handler::HandlerProc)
      super(handler)
    end

    protected def dispatch(io)
      deadline = Time.instant + @request_deadline
      spawn do
        OperationDeadline.run(deadline - Time.instant) { handle_client(io) }
      end
    end
  end

  class Server
    MAX_BODY = 16 * 1024
    @http_server : HTTP::Server? = nil
    @stop_requested = false
    @routes : Hash(String, Route)? = nil

    # A control connection idle for *idle_timeout* is dropped, and each request
    # must arrive and be answered within *request_deadline*, so a client that
    # trickles its request cannot hold the daemon. scripts/check latte-ipc
    # proves this with scaled-down values.
    getter idle_timeout : Time::Span
    getter request_deadline : Time::Span

    def initialize(@registry : Registry,
                   @services : ServiceControl,
                   @idle_timeout : Time::Span = 5.seconds,
                   @request_deadline : Time::Span = 12.seconds)
    end

    def listen : Nil
      server = DeadlineServer.new(@request_deadline) do |context|
        response = handle(context.request)
        context.response.status_code = response.status
        response.headers.each { |key, values| context.response.headers[key] = values }
        context.response.print(response.body)
        if @stop_requested
          # Deliver the answer before the daemon exits.
          context.response.close
          close
        end
      end
      server.max_request_line_size = 2048
      server.max_headers_size = 16 * 1024
      socket = OwnerServer.new(@registry.paths.control_socket, @idle_timeout)
      server.bind(socket)
      @http_server = server
      server.listen
    ensure
      server.try { |http| http.close unless http.closed? }
      @http_server = nil
    end

    def close : Nil
      @http_server.try(&.close)
    end

    VERSIONED = /\A\/v(\d+)(\/.*)\z/

    alias Route = Proc(HTTP::Request, Int32, Caramel::Response)

    # Routes /vN/… to the same handlers for every version N in `ControlAPI::VERSIONS`;
    # a path without a version is unknown, and an unserved version is `unsupported_api`.
    def handle(request : HTTP::Request) : Caramel::Response
      match = request.path.match(VERSIONED)
      return serve(request, ControlAPI::VERSIONS.first, nil) unless match
      return unsupported_api(match[1]) unless ControlAPI::VERSIONS.includes?(match[1].to_i?)

      serve(request, match[1].to_i, match[2])
    end

    private def serve(request : HTTP::Request, version : Int32, route : String?) : Caramel::Response
      OperationDeadline.check!
      found = route.try { |path| dispatch(request, version, path) }
      found || failure(version, "not_found", "Unknown Latte endpoint", 404)
    rescue DeadlineExceeded
      message = "Operation timed out; retry after checking Latte services"
      failure(version, "operation_timeout", message, 503)
    rescue ex : PublicError
      failure(version, ex.code, ex.message || "Service operation failed", ex.status)
    rescue ex : StateFormat::Newer
      message = ex.message || "Latte state was written by a newer Caramel"
      failure(version, "newer_state", message, 409)
    rescue JSON::ParseException | TypeCastError
      message = "Expected a JSON object with the documented fields"
      failure(version, "invalid_json", message, 400)
    rescue ex : ArgumentError
      failure(version, "invalid_request", ex.message || "Invalid request", 400)
    rescue ex
      request_id = UUID.random.to_s
      STDERR.puts("Latte request #{request_id}: #{ex.class}")
      message = "Service operation failed; check Latte logs (#{request_id})"
      failure(version, "internal_error", message, 500)
    end

    private def dispatch(request : HTTP::Request,
                         version : Int32,
                         route : String) : Caramel::Response?
      table = @routes ||= routes
      if handler = table["#{request.method} #{route}"]?
        return handler.call(request, version)
      end

      trace_route(request, version, route) ||
        branch_route(request, version, route) ||
        worker_route(request, version, route) ||
        site_route(request, version, route)
    end

    # The local trace collector's reads, from version 2 on: `GET /traces?limit=N` and
    # `GET /traces/<32 hex>`.
    private def trace_route(request : HTTP::Request,
                            version : Int32,
                            route : String) : Caramel::Response?
      return unless version >= 2 && request.method == "GET"

      if route == "/traces"
        limit = (request.query_params["limit"]?.try(&.to_i?) || 50).clamp(1, 200)
        json(@services.traces_json(limit))
      elsif match = route.match(/\A\/traces\/([0-9a-f]{32})\z/)
        json(@services.trace_json(match[1]))
      end
    end

    # The routes without an identifier in their path.
    private def routes : Hash(String, Route)
      {
        "GET /status" => ->(_request : HTTP::Request, version : Int32) do
          json(@services.status_json(version))
        end,
        "GET /sites" => ->(_request : HTTP::Request, version : Int32) do
          sites = @registry.list.map { |site| summary(site, version) }
          json({version: version, sites: sites}.to_json)
        end,
        "POST /sites" => ->(request : HTTP::Request, version : Int32) do
          register(request, version)
        end,
        "POST /services/start" => ->(request : HTTP::Request, version : Int32) do
          body(request, [] of String)
          OperationDeadline.check!
          @services.start_services
          json(@services.status_json(version))
        end,
        "POST /services/stop" => ->(request : HTTP::Request, version : Int32) do
          body(request, [] of String)
          OperationDeadline.check!
          @services.stop_services
          json(@services.status_json(version))
        end,
        "POST /daemon/stop" => ->(request : HTTP::Request, version : Int32) do
          # Ends this daemon; managed services keep running and are adopted by the next one.
          body(request, [] of String)
          @stop_requested = true
          json({version: version, stopping: true}.to_json)
        end,
      }
    end

    private def register(request : HTTP::Request, version : Int32) : Caramel::Response
      fields = body(request, %w[name directory suffix])
      OperationDeadline.check!
      site = OperationDeadline.run(12.seconds) do
        suffix = fields["suffix"]?.try(&.as_s) || "caramel"
        @services.register(string(fields, "name"), string(fields, "directory"), suffix)
      end
      json({version: version, site: summary(site, version)}.to_json, 201)
    end

    private def branch_route(request : HTTP::Request,
                             version : Int32,
                             route : String) : Caramel::Response?
      match = route.match(/\A\/sites\/([0-9a-f]{16})\/branches(?:\/([^\/]+))?\z/) || return
      id, name = match[1], match[2]?
      if name && request.method == "DELETE"
        removed = OperationDeadline.run(12.seconds) { @services.drop_branch(id, name) }
        return failure(version, "not_found", "Branch does not exist", 404) unless removed
        json({version: version, removed: name}.to_json)
      elsif name.nil? && request.method == "GET"
        json(stamped(OperationDeadline.run(12.seconds) { @services.branches_json(id) }, version))
      elsif name.nil? && request.method == "POST"
        fields = body(request, %w[name])
        OperationDeadline.check!
        branch = OperationDeadline.run(12.seconds) do
          @services.create_branch_json(id, string(fields, "name"))
        end
        json(stamped(branch, version), 201)
      end
    end

    # POST creates or resets Corretto test worker N; DELETE drops it. The service
    # validates N (a non-numeric segment arrives as 0).
    private def worker_route(request : HTTP::Request,
                             version : Int32,
                             route : String) : Caramel::Response?
      match = route.match(/\A\/sites\/([0-9a-f]{16})\/test-workers\/([^\/]+)\z/) || return
      id = match[1]
      index = match[2].matches?(/\A[0-9]{1,2}\z/) ? match[2].to_i : 0
      if request.method == "POST"
        body(request, [] of String)
        OperationDeadline.check!
        created = OperationDeadline.run(12.seconds) { @services.test_worker_json(id, index) }
        json(stamped(created, version))
      elsif request.method == "DELETE"
        removed = OperationDeadline.run(12.seconds) { @services.drop_test_worker(id, index) }
        return failure(version, "not_found", "Test worker does not exist", 404) unless removed
        json({version: version, removed: index}.to_json)
      end
    end

    private def site_route(request : HTTP::Request,
                           version : Int32,
                           route : String) : Caramel::Response?
      match = route.match(/\A\/sites\/([0-9a-f]{16})(\/(?:upstream|environment))?\z/) || return
      id, action = match[1], match[2]?
      case {request.method, action}
      when {"DELETE", nil}
        removed = OperationDeadline.run(12.seconds) { @services.unregister(id) }
        return failure(version, "not_found", "Project is not registered", 404) unless removed
        json({version: version, removed: id}.to_json)
      when {"POST", "/upstream"}
        fields = body(request, %w[socket])
        OperationDeadline.check!
        site = OperationDeadline.run(12.seconds) do
          @services.set_upstream(id, string(fields, "socket"))
        end
        json({version: version, site: summary(site, version)}.to_json)
      when {"POST", "/environment"}
        fields = body(request, %w[directory])
        OperationDeadline.check!
        json(stamped(@services.environment_json(id, string(fields, "directory")), version))
      when {"DELETE", "/upstream"}
        fields = body(request, %w[socket])
        OperationDeadline.check!
        cleared = OperationDeadline.run(12.seconds) do
          @services.clear_upstream(id, string(fields, "socket"))
        end
        json({version: version, cleared: cleared}.to_json)
      end
    end

    # *content*, a service's JSON document, stamped with the version asked for. A version 1
    # document is returned as it is.
    private def stamped(content : String, version : Int32) : String
      return content if version == 1

      document = JSON.parse(content).as_h
      document["version"] = JSON::Any.new(version.to_i64)
      document.to_json
    end

    # The latest API version this Latte serves, and a message naming the rest.
    private def unsupported_api(requested : String) : Caramel::Response
      versions = ControlAPI::VERSIONS
      message = "Latte #{Caramel::VERSION} serves control API #{versions.join(", ")}, " \
                "not #{requested}"
      document = {
        version: versions.max,
        latte:   Caramel::VERSION,
        api:     versions,
        error:   {code: "unsupported_api", message: message},
      }
      json(document.to_json, 404)
    end

    private def body(request : HTTP::Request, allowed : Array(String)) : Hash(String, JSON::Any)
      media_type = request.headers["Content-Type"]?.try(&.split(';').first.strip.downcase)
      unless media_type == "application/json"
        raise PublicError.new("unsupported_media_type", "Use application/json", 415)
      end
      bytes = Bytes.new(MAX_BODY + 1)
      length = request.body.try(&.read_greedy(bytes)) || 0
      raise PublicError.new("request_too_large", "Request exceeds 16 KiB", 413) if length > MAX_BODY
      fields = JSON.parse(String.new(bytes[0, length])).as_h
      unless (fields.keys - allowed).empty?
        raise ArgumentError.new("Request contains unsupported fields")
      end
      fields
    end

    private def string(fields : Hash(String, JSON::Any), name : String) : String
      value = fields[name]?.try(&.as_s)
      raise ArgumentError.new("Missing #{name}") unless value
      value
    end

    # A site as the control API lists it. Version 2 adds the development session's error
    # count and its newest error.
    private def summary(site : Site, version : Int32)
      status = ProjectStatus.read(@registry.paths, site)
      listed = {
        id:        site.id,
        name:      site.name,
        directory: site.directory,
        suffix:    site.suffix,
        domain:    site.domain,
        origin:    site.origin,
        upstream:  site.upstream,
        state:     status[:state],
        owner:     status[:owner],
      }
      return listed if version < 2

      listed.merge(errors: status[:errors], last_error: status[:last_error])
    end

    private def json(content : String, status : Int32 = 200) : Caramel::Response
      Caramel::Response.new(status, content, HTTP::Headers{
        "Content-Type" => "application/json", "Content-Length" => content.bytesize.to_s,
        "Cache-Control" => "no-store", "Connection" => "close",
      })
    end

    private def failure(version : Int32,
                        code : String,
                        message : String,
                        status : Int32) : Caramel::Response
      json({version: version, error: {code: code, message: message}}.to_json, status)
    end
  end
end
