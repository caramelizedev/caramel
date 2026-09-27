require "./support/harness"

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
    Caramel::Checks.fail("development diagnostic code must be absent from production binary") unless present == (mode == "development")
    {"production", "development", "test"}.each do |environment|
      {false, true}.each do |partial|
        env = {
          "CARAMEL_PROJECT_ROOT" => fixture,
          "APP_SECRET" => "s" * 64,
          "DATABASE_URL" => "postgresql://user:database-secret@private-host/app",
          "CARAMEL_ENV" => environment,
        } of String => String?
        result = Caramel::Checks.run([binary] + (partial ? ["partial"] : [] of String), env: env, timeout: 1.hour)
        Caramel::Checks.fail(result.stdout + result.stderr) unless result.success?
        response = JSON.parse(result.stdout)
        body = response["body"].as_s
        Caramel::Checks.fail("unexpected runtime response") unless response["status"].as_i == 500 && !!(response["headers"]["X-Request-ID"][0].as_s =~ /\A[0-9a-f-]{36}\z/)
        {"s" * 64, "private-password", "database-secret"}.each do |secret|
          Caramel::Checks.fail("secret was reflected in diagnostics") if body.includes?(secret)
        end
        if mode == environment && environment == "development"
          Caramel::Checks.fail(body) unless body.includes?(marker) && body.includes?("Missing helper &lt;unsafe&gt;")
          Caramel::Checks.fail(body) unless body =~ /app\/controller\.cr:\d+/
          Caramel::Checks.fail(body) unless body.split("<details>", 2)[0] =~ /app\/controller\.cr:\d+/
          Caramel::Checks.fail(body) unless body.includes?("Internal stack frames") && body.includes?("<details>")
          Caramel::Checks.fail(body) unless body.includes?("<!DOCTYPE html>") != partial
        else
          Caramel::Checks.fail(body) if body.includes?(marker) || body.includes?("Missing helper")
          Caramel::Checks.fail(body) unless body.includes?("Something went wrong")
        end
      end
    end
    puts "PASS: #{mode} build error visibility and redaction"
  end
end
