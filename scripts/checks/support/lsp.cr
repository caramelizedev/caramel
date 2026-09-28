require "./harness"
require "uri"

module Caramel::Checks
  class LSPClient
    getter name : String
    getter diagnostics : Hash(String, Array(JSON::Any))
    @reader_error : String?
    @stderr : File
    @process : Process

    def self.uri(path : String) : String
      "file://#{URI.encode_path(File.expand_path(path))}"
    end

    def self.path_of(uri : String) : String
      File.realpath(URI.decode(URI.parse(uri).path))
    end

    # LSP columns count UTF-16 code units, not UTF-8 bytes or Unicode scalars.
    def self.position(text : String, needle : String, offset : Int32 = 0) : Hash(String, Int32)
      target = (text.index(needle) || raise "Missing #{needle.inspect}") + offset
      line = 0
      column = 0
      text.each_char.with_index do |char, index|
        break if index >= target
        if char == '\n'
          line += 1
          column = 0
        else
          column += char.ord > 0xffff ? 2 : 1
        end
      end
      {"line" => line, "character" => column}
    end

    def initialize(@name : String, cwd : String, env : Hash(String, String?))
      @diagnostics = Hash(String, Array(JSON::Any)).new
      @messages = Channel(JSON::Any?).new(128)
      @writer_lock = Mutex.new
      @next_id = 0
      @reader_error = nil
      @stderr = File.tempfile("caramel-lsp-", dir: "/private/tmp")
      @process = begin
        Process.new([File.join(REPO, "bin/frappe"), "lsp", @name], chdir: cwd,
          env: env, clear_env: true, input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe, error: @stderr)
      rescue ex
        @stderr.close
        File.delete(@stderr.path) if File.exists?(@stderr.path)
        raise ex
      end
      spawn { read_messages }
      begin
        root = File.realpath(cwd)
        root_uri = LSPClient.uri(root)
        initialized = request("initialize", {
          "processId"        => Process.pid,
          "rootUri"          => root_uri,
          "rootPath"         => root,
          "workspaceFolders" => [{"uri" => root_uri, "name" => File.basename(root)}],
          "capabilities"     => {
            "workspace"    => {"configuration" => true},
            "textDocument" => {
              "synchronization"    => {"didSave" => true},
              "publishDiagnostics" => {} of String => String,
              "hover"              => {"contentFormat" => ["markdown", "plaintext"]},
              "definition"         => {} of String => String,
              "completion"         => {"completionItem" => {"snippetSupport" => false}},
            },
          },
        }, 60.seconds)
        if @name == "crystalline"
          sync = initialized.try { |value| value["capabilities"]?.try { |capabilities| capabilities["textDocumentSync"]? } }
          unless sync && sync.as_h? && sync["save"]?.try(&.as_bool?) == true && sync["change"]?.try(&.as_i?) == 2
            fail("crystalline did not advertise incremental sync and didSave: #{sync.inspect}")
          end
        end
        notify("initialized", {} of String => String)
      rescue ex
        @process.terminate(graceful: false) unless @process.terminated?
        @process.wait
        @stderr.close
        File.delete(@stderr.path) if File.exists?(@stderr.path)
        raise ex
      end
    end

    private def read_messages : Nil
      stream = @process.output.not_nil!
      loop do
        length : Int32? = nil
        loop do
          line = stream.gets || return
          break if line.strip.empty?
          header, separator, value = line.partition(':')
          length = value.strip.to_i if !separator.empty? && header.downcase == "content-length"
        end
        raise "LSP frame has no Content-Length" unless length
        raise "LSP frame is too large" if length > 16 * 1024 * 1024 || length < 0
        data = Bytes.new(length)
        stream.read_fully(data)
        message = JSON.parse(String.new(data))
        if method = message["method"]?
          if identifier = message["id"]?
            response = if method.as_s == "workspace/configuration"
                         Array.new(message["params"]["items"].as_a.size) { {} of String => String }
                       end
            send_message({"jsonrpc" => "2.0", "id" => identifier, "result" => response})
            next
          end
        end
        @messages.send(message)
      end
    rescue ex
      @reader_error = ex.message
    ensure
      @messages.send(nil)
    end

    private def send_message(message) : Nil
      body = message.to_json
      @writer_lock.synchronize do
        stream = @process.input.not_nil!
        stream << "Content-Length: " << body.bytesize << "\r\n\r\n" << body
        stream.flush
      end
    end

    def notify(method : String, params) : Nil
      send_message({"jsonrpc" => "2.0", "method" => method, "params" => params})
    end

    private def next_message(deadline : Time::Instant) : JSON::Any?
      remaining = deadline - Time.instant
      return if remaining <= Time::Span.zero
      event = select
      when message = @messages.receive
        {true, message}
      when timeout(remaining)
        {false, nil}
      end
      received, message = event
      fail("server exited#{@reader_error.try { |error| ": #{error}" } || ""}") if received && message.nil?
      if message && message["method"]?.try(&.as_s?) == "textDocument/publishDiagnostics"
        params = message["params"]
        @diagnostics[LSPClient.path_of(params["uri"].as_s)] = params["diagnostics"].as_a
      end
      message
    end

    def request(method : String, params, timeout : Time::Span = 30.seconds) : JSON::Any?
      @next_id += 1
      identifier = @next_id
      send_message({"jsonrpc" => "2.0", "id" => identifier, "method" => method, "params" => params})
      deadline = Time.instant + timeout
      while Time.instant < deadline
        message = next_message(deadline)
        if message && message["id"]?.try(&.as_i?) == identifier && !message["method"]?
          return if message["error"]?
          result = message["result"]?
          return if result.nil? || result.raw.nil?
          return result
        end
      end
      fail("#{method} timed out")
    end

    def wait_diagnostics(path : String, timeout : Time::Span, & : JSON::Any -> Bool) : Bool
      key = File.realpath(path)
      deadline = Time.instant + timeout
      loop do
        return true if (@diagnostics[key]? || [] of JSON::Any).any? { |item| yield item }
        return false if Time.instant >= deadline
        next_message(deadline)
      end
    end

    def open(path : String, text : String = File.read(path)) : String
      notify("textDocument/didOpen", {"textDocument" => {"uri" => LSPClient.uri(path), "languageId" => "crystal", "version" => 1, "text" => text}})
      text
    end

    def save(path : String) : Nil
      notify("textDocument/didSave", {"textDocument" => {"uri" => LSPClient.uri(path)}, "text" => File.read(path)})
    end

    def at(method : String, path : String, position : Hash(String, Int32), timeout : Time::Span = 30.seconds) : JSON::Any?
      request(method, {"textDocument" => {"uri" => LSPClient.uri(path)}, "position" => position}, timeout)
    end

    def definition_until(path : String, position : Hash(String, Int32), timeout : Time::Span, & : String -> Bool) : Array(String)
      deadline = Time.instant + timeout
      found = [] of String
      while Time.instant < deadline
        remaining = deadline - Time.instant
        response = at("textDocument/definition", path, position, remaining < 1.second ? 1.second : remaining)
        locations = case response
                    when Nil then [] of JSON::Any
                    else
                      response.as_a? || [response]
                    end
        found = locations.map { |location| LSPClient.path_of((location["targetUri"]? || location["uri"]).as_s) }
        return found if found.any? { |item| yield item }
        sleep 2.seconds if Time.instant < deadline
      end
      fail("definition did not resolve as expected; last result: #{found.inspect}")
    end

    def stderr_text : String
      @stderr.flush
      File.read(@stderr.path)
    end

    def fail(reason : String) : NoReturn
      raise "#{@name}: #{reason}\n--- server stderr ---\n#{stderr_text}"
    end

    def close : Nil
      unless @process.terminated?
        request("shutdown", nil, 10.seconds)
        notify("exit", nil)
        Caramel::Checks.wait_until(10.seconds, 50.milliseconds) { @process.terminated? }
      end
    rescue
    ensure
      if @process.terminated?
        @process.wait
      else
        Caramel::Checks.stop(@process)
      end
      @stderr.close
      File.delete(@stderr.path) if File.exists?(@stderr.path)
    end
  end
end
