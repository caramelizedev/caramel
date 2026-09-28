require "./html"
require "./response"

module Caramel
  # Application requires this file only in a development build. Runtime mode
  # is checked separately so a development binary cannot expose details when
  # accidentally started with production configuration.
  module DevelopmentError
    def self.response(error : Exception, request_id : String, request : HTTP::Request) : Response
      root = File.expand_path(ENV["CARAMEL_PROJECT_ROOT"]? || Dir.current)
      secrets = [] of String
      ENV.each do |key, value|
        next unless key.matches?(/SECRET|PASSWORD|TOKEN|API_KEY|DATABASE_URL/i)
        secrets << value unless value.empty?
        if value.starts_with?("postgres://") || value.starts_with?("postgresql://")
          URI.parse(value).password.try { |password| secrets << URI.decode(password) unless password.empty? }
        end
      end
      frames = error.backtrace?.try(&.first(80)) || [] of String
      application, internal = frames.partition do |frame|
        if location = frame.match(/\A(.+?):\d+(?::\d+)?(?: |\z)/)
          # Crystal renders paths relative to the process's initial directory.
          # Normalize for classification without opening arbitrary source files.
          path = File.expand_path(location[1], Process::INITIAL_PWD || Dir.current)
          %w[app config src db].any? { |directory| path.starts_with?("#{root}/#{directory}/") }
        else
          false
        end
      end
      name = HTML.escape(error.class.to_s)
      message = HTML.escape(redact(error.message || "No exception message", secrets, 8192))
      content = String.build do |io|
        io << "<section class=\"development-error\"><p>CARAMEL DEVELOPMENT EXCEPTION</p><h1>" << name << "</h1><pre>" << message << "</pre>"
        io << "<h2>Application location</h2>"
        if application.empty?
          io << "<p>No application frame was available. Expand the stack below for the failing dependency.</p>"
        else
          io << "<ol>"
          application.each { |frame| io << "<li><code>" << HTML.escape(redact(frame.gsub(root + "/", ""), secrets, 2048)) << "</code></li>" }
          io << "</ol>"
        end
        io << "<p>Check the first application frame, fix the failing operation, and save your changes. Frappé will rebuild the application.</p>"
        io << "<details><summary>Internal stack frames</summary><ol>"
        internal.each { |frame| io << "<li><code>" << HTML.escape(redact(frame, secrets, 2048)) << "</code></li>" }
        io << "</ol></details><p>Request reference: <code>" << HTML.escape(request_id) << "</code></p></section>"
      end
      title = "<title>#{name} · Caramel development</title>"
      full = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">#{title}<link rel=\"stylesheet\" href=\"/__caramel/dev/style.css\"></head><body><main>#{content}</main></body></html>"
      response = Response.html(request, full: full, partial: title + content, status: 500)
      response.headers["X-Request-ID"] = request_id
      response.headers["Cache-Control"] = "no-store"
      response
    end

    private def self.redact(text : String, secrets : Array(String), limit : Int32) : String
      safe = text.scrub
      secrets.sort_by(&.bytesize).reverse_each { |secret| safe = safe.gsub(secret, "[redacted]") }
      safe = safe.gsub(/postgres(?:ql)?:\/\/[^\s"'<>]+/, "[database URL redacted]")
      safe = safe.gsub(/\b[A-Za-z0-9_]*(?:password|secret|token|api_key)\s*[=:]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)/i, "[credential redacted]")
      safe.byte_slice(0, Math.min(safe.bytesize, limit)).scrub
    end
  end
end
