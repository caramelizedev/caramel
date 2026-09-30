require "./support/harness"

PRODUCTION_LEAK = "development diagnostic code must be absent from production binary"
REQUEST_ID      = /\A[0-9a-f-]{36}\z/

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
    present = File.read(binary).includes?(marker)
    Caramel::Checks.fail(PRODUCTION_LEAK) unless present == (mode == "development")
    {"production", "development", "test"}.each do |environment|
      {false, true}.each do |partial|
        env = {
          "CARAMEL_PROJECT_ROOT" => fixture,
          "APP_SECRET"           => "s" * 64,
          "DATABASE_URL"         => "postgresql://user:database-secret@private-host/app",
          "CARAMEL_ENV"          => environment,
        } of String => String?
        arguments = partial ? ["partial"] : [] of String
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
        if mode == environment && environment == "development"
          escaped = body.includes?("Missing helper &lt;unsafe&gt;")
          Caramel::Checks.fail(body) unless body.includes?(marker) && escaped
          Caramel::Checks.fail(body) unless body =~ /app\/controller\.cr:\d+/
          summary = body.split("<details>", 2)[0]
          Caramel::Checks.fail(body) unless summary =~ /app\/controller\.cr:\d+/
          frames = body.includes?("Internal stack frames")
          Caramel::Checks.fail(body) unless frames && body.includes?("<details>")
          Caramel::Checks.fail(body) unless body.includes?("<!DOCTYPE html>") != partial
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
