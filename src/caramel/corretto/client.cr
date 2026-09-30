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

  # A fixture file to upload:
  #
  #     Corretto.upload("spec/fixtures/cover.png", "image/png")
  def self.upload(path : String,
                  content_type : String? = nil,
                  filename : String = File.basename(path)) : Upload
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
    LOCAL_PATH = "Corretto requests take a local path such as /books"
    ONE_BODY   = "Send one body: params: (with files: for multipart), json: or body:"
    GET_BODY   = "GET sends params: in the query and takes no body"
    NO_HOST    = "Corretto needs an application origin with a host"

    getter cookies = {} of String => String
    @origin : String
    @host : String
    @last : Caramel::Response? = nil

    def initialize(@application : Caramel::Application)
      @origin = @application.csrf.origin
      @host = URI.parse(@origin).authority ||
              raise ArgumentError.new("#{NO_HOST}, not #{@origin}")
    end

    {% for verb in %w[get post put patch delete] %}
      def {{ verb.id }}(path : String, *,
                        headers : Hash(String, String) = {} of String => String,
                        params : Hash(String, _) = {} of String => String,
                        files : Hash(String, Upload) = {} of String => Upload,
                        json = nil,
                        body : (String | Bytes)? = nil) : Caramel::Response
        request({{ verb.upcase }}, path, headers, params,
          files: files, json: json, body: body)
      end
    {% end %}

    def request(method : String, path : String,
                headers : Hash(String, String) = {} of String => String,
                params : Hash(String, _) = {} of String => String,
                *,
                files : Hash(String, Upload) = {} of String => Upload,
                json = nil,
                body : (String | Bytes)? = nil) : Caramel::Response
      refuse_misuse(method, path,
        form: !params.empty?, files: !files.empty?, json: !json.nil?, raw: !body.nil?)
      sent = HTTP::Headers{"Host" => @host}
      payload = nil
      if method == "GET"
        path = with_query(path, params)
      else
        sent["Origin"] = @origin
        sent["X-CSRF-Token"] = csrf_token
        payload = encode(sent, params, files, json, body)
      end
      unless @cookies.empty?
        sent["Cookie"] = @cookies.join("; ") { |name, value| "#{name}=#{value}" }
      end
      headers.each { |name, value| sent[name] = value }
      respond(HTTP::Request.new(method, path, sent, payload))
    end

    # Requests the Location (or htmx's HX-Location) of the last response.
    def follow_redirect : Caramel::Response
      last = @last || raise Error.new("follow_redirect needs a previous response")
      location = last.headers["HX-Location"]? || redirect_location(last)
      unless location
        raise Error.new("The last response (status #{last.status}) is not a redirect")
      end
      get(location)
    end

    # Signs `user` in the way the application does: `user_id` in the signed
    # session cookie.
    def sign_in(user) : Nil
      sessions = @application.sessions
      cookie = @cookies[Caramel::Session::COOKIE_NAME]?
      session = cookie.try { |value| sessions.decode(value) } || {} of String => String
      session["user_id"] = user.id.to_s
      @cookies[Caramel::Session::COOKIE_NAME] = sessions.encode(session)
    end

    private def refuse_misuse(method : String, path : String, *,
                              form : Bool, files : Bool, json : Bool, raw : Bool) : Nil
      raise ArgumentError.new("#{LOCAL_PATH}, not #{path.inspect}") unless local?(path)
      raise ArgumentError.new(ONE_BODY) if [form || files, json, raw].count(true) > 1
      raise ArgumentError.new(GET_BODY) if method == "GET" && (files || json || raw)
    end

    private def local?(path : String) : Bool
      path.starts_with?('/') && !path.starts_with?("//")
    end

    # A 3xx response's Location, if it sends one.
    private def redirect_location(response : Caramel::Response) : String?
      response.headers["Location"]? if (300..399).includes?(response.status)
    end

    # The token a page from this application would submit, kept as its cookie.
    private def csrf_token : String
      @cookies[Caramel::CSRF::COOKIE_NAME] ||= @application.csrf.issue
    end

    private def with_query(path : String, params : Hash(String, _)) : String
      return path if params.empty?

      "#{path}#{path.includes?('?') ? '&' : '?'}#{form(params)}"
    end

    # The body of a write, with the Content-Type it implies.
    private def encode(sent : HTTP::Headers,
                       params : Hash(String, _),
                       files : Hash(String, Upload),
                       json,
                       body : (String | Bytes)?) : (String | Bytes)?
      return multipart(params, files, sent) unless files.empty?
      return body if body

      unless json.nil?
        sent["Content-Type"] = "application/json"
        return json.to_json
      end
      return if params.empty?

      sent["Content-Type"] = "application/x-www-form-urlencoded"
      form(params)
    end

    private def form(params : Hash(String, _)) : String
      URI::Params.build do |builder|
        params.each { |key, value| builder.add(key, value.to_s) }
      end
    end

    private def multipart(params : Hash(String, _),
                          files : Hash(String, Upload),
                          sent : HTTP::Headers) : Bytes
      io = IO::Memory.new
      builder = HTTP::FormData::Builder.new(io)
      params.each { |name, value| builder.field(name, value.to_s) }
      files.each { |name, upload| attach(builder, name, upload) }
      builder.finish
      sent["Content-Type"] = builder.content_type
      io.to_slice
    end

    private def attach(builder : HTTP::FormData::Builder,
                       name : String,
                       upload : Upload) : Nil
      metadata = HTTP::FormData::FileMetadata.new(filename: upload.filename)
      headers = HTTP::Headers.new
      upload.content_type.try { |type| headers["Content-Type"] = type }
      builder.file(name, IO::Memory.new(upload.content), metadata, headers)
    end

    # Sends the request in-process and keeps what a browser would.
    private def respond(request : HTTP::Request) : Caramel::Response
      response = collect(@application.handle(request))
      remember(response)
      @last = response
    end

    # A streamed response, read to its end.
    private def collect(response : Caramel::Response) : Caramel::Response
      streamer = response.streamer || return response
      streamed = IO::Memory.new
      streamer.call(streamed)
      Caramel::Response.new(response.status, streamed.to_s, response.headers)
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
