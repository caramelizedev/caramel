require "http"
require "uri"
require "uri/params"

module Corretto
  # A browser-like client that sends requests to the application in-process,
  # through `Caramel::Application#handle`, in the example's fiber (so requests
  # share the example's transaction). It keeps a cookie jar and adds `Host`,
  # and for body methods the exact `Origin` and the `X-CSRF-Token` a page
  # would submit. Headers passed to a request override the automatic ones.
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
      # Params are encoded in the query for GET and as a URL-encoded form otherwise.
      def {{ verb.id }}(path : String, *, headers : Hash(String, String) = {} of String => String, params : Hash(String, _) = {} of String => String) : Caramel::Response
        request({{ verb.upcase }}, path, headers, params)
      end
    {% end %}

    def request(method : String, path : String, headers : Hash(String, String) = {} of String => String, params : Hash(String, _) = {} of String => String) : Caramel::Response
      raise ArgumentError.new("Corretto requests take a local path such as /books, not #{path.inspect}") if !path.starts_with?('/') || path.starts_with?("//")
      form = URI::Params.build { |builder| params.each { |key, value| builder.add(key, value.to_s) } }
      sent = HTTP::Headers{"Host" => @host}
      body = nil
      if method == "GET"
        path = "#{path}#{path.includes?('?') ? '&' : '?'}#{form}" unless params.empty?
      else
        sent["Origin"] = @origin
        token = @cookies[Caramel::CSRF::COOKIE_NAME] ||= @application.csrf.issue
        sent["X-CSRF-Token"] = token
        unless params.empty?
          sent["Content-Type"] = "application/x-www-form-urlencoded"
          body = form
        end
      end
      sent["Cookie"] = @cookies.join("; ") { |name, value| "#{name}=#{value}" } unless @cookies.empty?
      headers.each { |name, value| sent[name] = value }
      response = @application.handle(HTTP::Request.new(method, path, sent, body))
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
