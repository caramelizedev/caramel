require "./harness"

module Caramel::Checks
  # A minimal W3C WebDriver client for safaridriver. Safari allows one
  # automation session at a time, so `open` always deletes the session and
  # stops the driver.
  class WebDriver
    ELEMENT_KEY = "element-6066-11e4-a52e-4f735466cecf"

    class Error < Exception; end

    record Element, id : String do
      def to_json(json : JSON::Builder) : Nil
        json.object { json.field ELEMENT_KEY, @id }
      end
    end

    def self.open(log : IO, capabilities = {browserName: "safari", acceptInsecureCerts: true}, &)
      driver = new(log)
      begin
        driver.start
        driver.create_session(capabilities)
        yield driver
      ensure
        driver.close
      end
    end

    def initialize(@log : IO, @executable : String = "/usr/bin/safaridriver")
      @port = Checks.free_tcp_port
      @process = nil.as(Process?)
      @session = nil.as(String?)
    end

    def start : Nil
      process = Process.new(@executable, ["--port", @port.to_s], output: @log, error: @log)
      @process = process
      ready = Checks.wait_until(15.seconds, 100.milliseconds) { process.terminated? || ready? }
      raise Error.new("safaridriver did not become ready on port #{@port}; run safaridriver --enable once") if !ready || process.terminated?
    end

    def create_session(capabilities) : String
      value = command("POST", "/session", {capabilities: {alwaysMatch: capabilities}})
      @session = value["sessionId"].as_s
    end

    def navigate(url : String) : Nil
      session_command("POST", "/url", {url: url})
    end

    def url : String
      session_command("GET", "/url").as_s
    end

    def execute(script : String, *args) : JSON::Any
      session_command("POST", "/execute/sync", {script: script, args: args})
    end

    def execute_async(script : String, *args) : JSON::Any
      session_command("POST", "/execute/async", {script: script, args: args})
    end

    def find(css : String) : Element
      element(session_command("POST", "/element", {using: "css selector", value: css}))
    end

    def click(element : Element) : Nil
      session_command("POST", "/element/#{element.id}/click", {} of String => String)
    end

    def send_keys(element : Element, text : String) : Nil
      session_command("POST", "/element/#{element.id}/value", {text: text})
    end

    def property(element : Element, name : String) : JSON::Any
      session_command("GET", "/element/#{element.id}/property/#{URI.encode_path_segment(name)}")
    end

    def close : Nil
      if session = @session
        @session = nil
        begin
          command("DELETE", "/session/#{session}")
        rescue ex
          @log.puts("WebDriver session cleanup failed: #{ex.message}")
        end
      end
      if process = @process
        @process = nil
        Checks.stop(process, 5.seconds)
      end
    end

    private def element(value : JSON::Any) : Element
      Element.new(value[ELEMENT_KEY]?.try(&.as_s?) || raise Error.new("WebDriver returned no element reference: #{value.to_json}"))
    end

    private def session_command(method : String, path : String, body = nil) : JSON::Any
      session = @session || raise Error.new("No WebDriver session")
      command(method, "/session/#{session}#{path}", body)
    end

    private def ready? : Bool
      status, document = exchange("GET", "/status", nil, 2.seconds)
      status == 200 && document["value"]["ready"].as_bool? == true
    rescue IO::Error | Socket::Error | JSON::ParseException
      false
    end

    private def command(method : String, path : String, body = nil) : JSON::Any
      status, document = exchange(method, path, body, 90.seconds)
      value = document["value"]? || JSON::Any.new(nil)
      unless 200 <= status < 300
        error = value["error"]?.try(&.as_s?) || "HTTP #{status}"
        message = value["message"]?.try(&.as_s?) || document.to_json
        raise Error.new("WebDriver #{method} #{path} failed: #{error}: #{message}")
      end
      value
    end

    private def exchange(method : String, path : String, body, timeout : Time::Span) : {Int32, JSON::Any}
      client = HTTP::Client.new("127.0.0.1", @port)
      client.connect_timeout = 2.seconds
      client.read_timeout = timeout
      headers = HTTP::Headers{"Content-Type" => "application/json; charset=utf-8"}
      response = client.exec(method, path, headers, body.nil? ? nil : body.to_json)
      {response.status_code, response.body.empty? ? JSON::Any.new(nil) : JSON.parse(response.body)}
    ensure
      client.try &.close
    end
  end
end
