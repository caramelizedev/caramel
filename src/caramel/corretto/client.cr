require "http"
require "http/formdata"
require "json"
require "uri"
require "uri/params"

module Corretto
  # A file part for a client's `files:`, as a browser uploads it.
  record Upload, content : Bytes, filename : String, content_type : String? = nil do
    def self.new(content : String, filename : String, content_type : String? = nil) : self
      new(content.to_slice, filename, content_type)
    end
  end

  # A fixture file to upload, such as `Corretto.upload("spec/fixtures/cover.png", "image/png")`.
  def self.upload(path : String, content_type : String? = nil, filename : String = File.basename(path)) : Upload
    Upload.new(File.open(path, &.getb_to_end), filename, content_type)
  end

  # A browser-like client that sends requests to the application in-process,
  # through `Caramel::Application#handle`, in the example's fiber (so requests
  # share the example's transaction). It keeps a cookie jar and adds `Host`,
  # and for body methods the exact `Origin` and the `X-CSRF-Token` a page
  # would submit. Headers passed to a request override the automatic ones.
  #
  # A request's body is one of:
  #
  # * `params:`, a URL-encoded form (for GET, the query);
  # * `params:` with `files:`, a multipart form;
  # * `json:`, any value, sent as `application/json`;
  # * `body:`, raw text or bytes, typed by a `Content-Type` in `headers:`.
  class Client
    getter cookies = {} of String => String
    @origin : String
    @host : String
    @last : Caramel::Response? = nil

    def initialize(@application : Caramel::Application)
      @origin = @application.csrf.origin
      @host = URI.parse(@origin).authority || raise ArgumentError.new("Corretto needs an application origin with a host, not #{@origin}")
    end

    {% for verb in %w[get post put patch delete] %}
      def {{ verb.id }}(path : String, *, headers : Hash(String, String) = {} of String => String, params : Hash(String, _) = {} of String => String,
                        json = nil, body : (String | Bytes)? = nil, files : Hash(String, Upload) = {} of String => Upload) : Caramel::Response
        request({{ verb.upcase }}, path, headers, params, json: json, body: body, files: files)
      end
    {% end %}

    def request(method : String, path : String, headers : Hash(String, String) = {} of String => String, params : Hash(String, _) = {} of String => String,
                *, json = nil, body : (String | Bytes)? = nil, files : Hash(String, Upload) = {} of String => Upload) : Caramel::Response
      check(method, path, !params.empty?, !files.empty?, !json.nil?, !body.nil?)
      sent = HTTP::Headers{"Host" => @host}
      payload = nil
      if method == "GET"
        path = "#{path}#{path.includes?('?') ? '&' : '?'}#{form(params)}" unless params.empty?
      else
        sent["Origin"] = @origin
        token = @cookies[Caramel::CSRF::COOKIE_NAME] ||= @application.csrf.issue
        sent["X-CSRF-Token"] = token
        payload = encode(sent, params, json, body, files)
      end
      sent["Cookie"] = @cookies.join("; ") { |name, value| "#{name}=#{value}" } unless @cookies.empty?
      headers.each { |name, value| sent[name] = value }
      response = @application.handle(HTTP::Request.new(method, path, sent, payload))
      if streamer = response.streamer
        streamed = IO::Memory.new
        streamer.call(streamed)
        response = Caramel::Response.new(response.status, streamed.to_s, response.headers)
      end
      remember(response)
      @last = response
    end

    # Requests the Location (or htmx's HX-Location) of the last response.
    def follow_redirect : Caramel::Response
      last = @last || raise Error.new("follow_redirect needs a previous response")
      location = last.headers["HX-Location"]? || ((300..399).includes?(last.status) ? last.headers["Location"]? : nil)
      raise Error.new("The last response (status #{last.status}) is not a redirect") unless location
      get(location)
    end

    # Signs `user` in the way the application does: `user_id` in the signed session cookie.
    def sign_in(user) : Nil
      sessions = @application.sessions
      session = @cookies[Caramel::Session::COOKIE_NAME]?.try { |value| sessions.decode(value) } || {} of String => String
      session["user_id"] = user.id.to_s
      @cookies[Caramel::Session::COOKIE_NAME] = sessions.encode(session)
    end

    private def check(method : String, path : String, params : Bool, files : Bool, json : Bool, raw : Bool) : Nil
      raise ArgumentError.new("Corretto requests take a local path such as /books, not #{path.inspect}") if !path.starts_with?('/') || path.starts_with?("//")
      raise ArgumentError.new("Send one body: params: (with files: for multipart), json: or body:") if [params || files, json, raw].count(true) > 1
      raise ArgumentError.new("GET sends params: in the query and takes no body") if method == "GET" && (files || json || raw)
    end

    # The body for a write, with the Content-Type it implies.
    private def encode(sent : HTTP::Headers, params : Hash(String, _), json, body : (String | Bytes)?, files : Hash(String, Upload)) : (String | Bytes)?
      if !files.empty?
        multipart(params, files, sent)
      elsif !json.nil?
        sent["Content-Type"] = "application/json"
        json.to_json
      elsif body
        body
      elsif !params.empty?
        sent["Content-Type"] = "application/x-www-form-urlencoded"
        form(params)
      end
    end

    private def form(params : Hash(String, _)) : String
      URI::Params.build { |builder| params.each { |key, value| builder.add(key, value.to_s) } }
    end

    private def multipart(params : Hash(String, _), files : Hash(String, Upload), sent : HTTP::Headers) : Bytes
      io = IO::Memory.new
      builder = HTTP::FormData::Builder.new(io)
      params.each { |name, value| builder.field(name, value.to_s) }
      files.each do |name, upload|
        headers = HTTP::Headers.new
        upload.content_type.try { |type| headers["Content-Type"] = type }
        builder.file(name, IO::Memory.new(upload.content), HTTP::FormData::FileMetadata.new(filename: upload.filename), headers)
      end
      builder.finish
      sent["Content-Type"] = builder.content_type
      io.to_slice
    end

    private def remember(response : Caramel::Response) : Nil
      response.headers.get?("Set-Cookie").try &.each do |header|
        next unless cookie = HTTP::Cookie::Parser.parse_set_cookie(header)
        if cookie.expired?
          @cookies.delete(cookie.name)
        else
          @cookies[cookie.name] = cookie.value
        end
      end
    end
  end
end
