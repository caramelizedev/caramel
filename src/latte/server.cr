require "http/server"
require "socket/unix_server"
require "json"
require "uuid"
require "./registry"
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
    abstract def status_json : String
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
    def initialize(path : String)
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
        socket.read_timeout = 5.seconds
        socket.write_timeout = 5.seconds
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
    protected def dispatch(io)
      deadline = Time.instant + 12.seconds
      spawn do
        OperationDeadline.run(deadline - Time.instant) { handle_client(io) }
      end
    end
  end

  class Server
    MAX_BODY = 16 * 1024
    @http_server : HTTP::Server? = nil
    @stop_requested = false

    def initialize(@registry : Registry, @services : ServiceControl)
    end

    def listen : Nil
      server = DeadlineServer.new do |context|
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
      socket = OwnerServer.new(@registry.paths.control_socket)
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

    def handle(request : HTTP::Request) : Caramel::Response
      OperationDeadline.check!
      path = request.path
      case {request.method, path}
      when {"GET", "/v1/status"}
        return json(@services.status_json)
      when {"GET", "/v1/sites"}
        return json({version: 1, sites: @registry.list.map { |site| summary(site) }}.to_json)
      when {"POST", "/v1/sites"}
        fields = body(request, %w(name directory suffix))
        OperationDeadline.check!
        site = OperationDeadline.run(12.seconds) do
          @services.register(string(fields, "name"), string(fields, "directory"), fields["suffix"]?.try(&.as_s) || "caramel")
        end
        return json({version: 1, site: summary(site)}.to_json, 201)
      when {"POST", "/v1/services/start"}
        body(request, [] of String)
        OperationDeadline.check!
        @services.start_services
        return json(@services.status_json)
      when {"POST", "/v1/services/stop"}
        body(request, [] of String)
        OperationDeadline.check!
        @services.stop_services
        return json(@services.status_json)
      when {"POST", "/v1/daemon/stop"}
        # Ends this daemon; managed services keep running and are adopted
        # by the next one.
        body(request, [] of String)
        @stop_requested = true
        return json({version: 1, stopping: true}.to_json)
      end
      if match = path.match(/\A\/v1\/sites\/([0-9a-f]{16})\/branches(?:\/([^\/]+))?\z/)
        id, name = match[1], match[2]?
        if name && request.method == "DELETE"
          removed = OperationDeadline.run(12.seconds) { @services.drop_branch(id, name) }
          return failure("not_found", "Branch does not exist", 404) unless removed
          return json({version: 1, removed: name}.to_json)
        elsif name.nil? && request.method == "GET"
          return json(OperationDeadline.run(12.seconds) { @services.branches_json(id) })
        elsif name.nil? && request.method == "POST"
          fields = body(request, %w(name))
          OperationDeadline.check!
          return json(OperationDeadline.run(12.seconds) { @services.create_branch_json(id, string(fields, "name")) }, 201)
        end
      end
      # POST creates or resets Corretto test worker N; DELETE drops it. The
      # service validates N (a non-numeric segment arrives as 0).
      if match = path.match(/\A\/v1\/sites\/([0-9a-f]{16})\/test-workers\/([^\/]+)\z/)
        id = match[1]
        index = match[2].matches?(/\A[0-9]{1,2}\z/) ? match[2].to_i : 0
        if request.method == "POST"
          body(request, [] of String)
          OperationDeadline.check!
          return json(OperationDeadline.run(12.seconds) { @services.test_worker_json(id, index) })
        elsif request.method == "DELETE"
          removed = OperationDeadline.run(12.seconds) { @services.drop_test_worker(id, index) }
          return failure("not_found", "Test worker does not exist", 404) unless removed
          return json({version: 1, removed: index}.to_json)
        end
      end
      if match = path.match(/\A\/v1\/sites\/([0-9a-f]{16})(\/(?:upstream|environment))?\z/)
        id = match[1]
        if request.method == "DELETE" && match[2]?.nil?
          removed = OperationDeadline.run(12.seconds) { @services.unregister(id) }
          return failure("not_found", "Project is not registered", 404) unless removed
          return json({version: 1, removed: id}.to_json)
        elsif request.method == "POST" && match[2]? == "/upstream"
          fields = body(request, %w(socket))
          OperationDeadline.check!
          site = OperationDeadline.run(12.seconds) { @services.set_upstream(id, string(fields, "socket")) }
          return json({version: 1, site: summary(site)}.to_json)
        elsif request.method == "POST" && match[2]? == "/environment"
          fields = body(request, %w(directory))
          OperationDeadline.check!
          return json(@services.environment_json(id, string(fields, "directory")))
        elsif request.method == "DELETE" && match[2]? == "/upstream"
          fields = body(request, %w(socket))
          OperationDeadline.check!
          cleared = OperationDeadline.run(12.seconds) { @services.clear_upstream(id, string(fields, "socket")) }
          return json({version: 1, cleared: cleared}.to_json)
        end
      end
      failure("not_found", "Unknown Latte endpoint", 404)
    rescue DeadlineExceeded
      failure("operation_timeout", "Operation timed out; retry after checking Latte services", 503)
    rescue ex : PublicError
      failure(ex.code, ex.message || "Service operation failed", ex.status)
    rescue JSON::ParseException | TypeCastError
      failure("invalid_json", "Expected a JSON object with the documented fields", 400)
    rescue ex : ArgumentError
      failure("invalid_request", ex.message || "Invalid request", 400)
    rescue ex
      request_id = UUID.random.to_s
      STDERR.puts("Latte request #{request_id}: #{ex.class}")
      failure("internal_error", "Service operation failed; check Latte logs (#{request_id})", 500)
    end

    private def body(request : HTTP::Request, allowed : Array(String)) : Hash(String, JSON::Any)
      unless request.headers["Content-Type"]?.try(&.split(';').first.strip.downcase) == "application/json"
        raise PublicError.new("unsupported_media_type", "Use application/json", 415)
      end
      bytes = Bytes.new(MAX_BODY + 1)
      length = request.body.try(&.read_greedy(bytes)) || 0
      raise PublicError.new("request_too_large", "Request exceeds 16 KiB", 413) if length > MAX_BODY
      fields = JSON.parse(String.new(bytes[0, length])).as_h
      raise ArgumentError.new("Request contains unsupported fields") unless (fields.keys - allowed).empty?
      fields
    end

    private def string(fields : Hash(String, JSON::Any), name : String) : String
      value = fields[name]?.try(&.as_s)
      raise ArgumentError.new("Missing #{name}") unless value
      value
    end

    private def summary(site : Site)
      status = ProjectStatus.read(@registry.paths, site)
      {id: site.id, name: site.name, directory: site.directory, suffix: site.suffix,
       domain: site.domain, origin: site.origin, upstream: site.upstream, state: status[:state], owner: status[:owner]}
    end

    private def json(content : String, status : Int32 = 200) : Caramel::Response
      Caramel::Response.new(status, content, HTTP::Headers{
        "Content-Type" => "application/json", "Content-Length" => content.bytesize.to_s,
        "Cache-Control" => "no-store", "Connection" => "close",
      })
    end

    private def failure(code : String, message : String, status : Int32) : Caramel::Response
      json({version: 1, error: {code: code, message: message}}.to_json, status)
    end
  end
end
