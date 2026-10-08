require "./support/harness"
require "../../src/caramel"
require "../../src/caramel/corretto/matchers"

include Corretto::Matchers

PRODUCTION_LEAK = "development diagnostic code must be absent from production binary"
REQUEST_ID      = /\A[0-9a-f-]{36}\z/
SINK            = "CARAMEL_DEV_EVENTS"
UNLINKED_SINK   = "the development build must carry the dev sink; " \
                  "the fixture does not link the Crema runtime"

fixture = File.join(Caramel::Checks::REPO, "spec/fixtures/runtime_errors")
marker = "CARAMEL DEVELOPMENT EXCEPTION"
root = Caramel::Checks.private_temp("caramel-errors-")
at_exit { FileUtils.rm_rf(root) }
begin
  {"production", "development"}.each do |mode|
    binary = File.join(root, mode)
    command = ["build", File.join(fixture, "main.cr"), "-o", binary]
    command.concat(["-D", "caramel_development"]) if mode == "development"
    build = Caramel::Checks.crystal(command, timeout: 1.hour)
    Caramel::Checks.fail(build.stdout + build.stderr) unless build.success?
    contents = File.read(binary)
    development = mode == "development"
    Caramel::Checks.fail(PRODUCTION_LEAK) unless contents.includes?(marker) == development
    Caramel::Checks.fail(PRODUCTION_LEAK) if !development && contents.includes?(SINK)
    Caramel::Checks.fail(UNLINKED_SINK) if development && !contents.includes?(SINK)
    {"production", "development", "test"}.each do |environment|
      {"full", "partial", "json"}.each do |variant|
        partial = variant == "partial"
        env = {
          "CARAMEL_PROJECT_ROOT" => fixture,
          "APP_SECRET"           => "s" * 64,
          "DATABASE_URL"         => "postgresql://user:database-secret@private-host/app",
          "CARAMEL_ENV"          => environment,
        } of String => String?
        arguments = variant == "full" ? [] of String : [variant]
        result = Caramel::Checks.run([binary] + arguments, env: env, timeout: 1.hour)
        Caramel::Checks.fail(result.stdout + result.stderr) unless result.success?
        response = JSON.parse(result.stdout)
        body = response["body"].as_s
        unexpected = response["status"].as_i != 500 ||
                     !(response["headers"]["X-Request-ID"][0].as_s =~ REQUEST_ID)
        Caramel::Checks.fail("unexpected runtime response") if unexpected
        {"s" * 64, "private-password", "database-secret"}.each do |secret|
          Caramel::Checks.fail("secret was reflected in diagnostics") if body.includes?(secret)
        end
        if mode == environment && environment == "development" && variant == "json"
          error = JSON.parse(body)["error"]
          Caramel::Checks.fail(body) unless error["class"] == "Exception"
          Caramel::Checks.fail(body) if error["backtrace"].as_a.empty?
          content_type = response["headers"]["Content-Type"][0].as_s
          Caramel::Checks.fail(body) unless content_type.includes?("json")
        elsif mode == environment && environment == "development"
          message = "Missing helper <unsafe> [credential redacted] " \
                    "[credential redacted] [redacted]"
          content = have_html {
            section(class: "development-error") {
              p { marker }
              pre { message }
              details { summary { "Internal stack frames" } }
            }
          }
          unless content.match(body)
            Caramel::Checks.fail(content.failure_message(body))
          end
          located = Corretto::HTML::Document.open(body) do |document|
            document.select("section.development-error > ol > li > code").any? do |node|
              node.inner_text.matches?(%r{app/controller\.cr:\d+})
            end
          end
          Caramel::Checks.fail(body) unless located
          page = render_page("Caramel development")
          Caramel::Checks.fail(body) unless page.match(Caramel::Response.new(500, body)) != partial
          editor = body.includes?(%(<a class="editor" href="zed://file/))
          source = body.includes?(%(<figure class="source">)) && body.includes?("<mark>")
          copy = body.includes?("data-caramel-copy")
          Caramel::Checks.fail("error page lacks an editor link") unless editor
          Caramel::Checks.fail("error page lacks its source excerpt") unless source
          Caramel::Checks.fail("error page lacks Copy as Markdown") unless copy
        else
          revealed = body.includes?(marker) || body.includes?("Missing helper")
          Caramel::Checks.fail(body) if revealed
          Caramel::Checks.fail(body) unless body.includes?("Something went wrong")
        end
      end
    end
    puts "PASS: #{mode} build error visibility and redaction"
  end
end
