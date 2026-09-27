require "./support/harness"
require "uri"
require "random/secure"

module Caramel::Checks::Integration
  extend self

  private def required(argv : Array(String), env : Hash(String, String?), input : String? = nil) : Caramel::Latte::ProcessResult
    result = Checks.run(argv, env: env, input: input, timeout: 120.seconds)
    raise "Integration harness failed: TimeoutExpired" if result.timed_out
    raise "Integration harness failed: CalledProcessError" unless result.success?
    result
  end

  private def url(database : String, user : String, password : String, host : String, port : Int32, ca : String? = nil) : String
    query = "host=#{URI.encode_www_form(host)}&port=#{port}&sslmode=#{ca ? "verify-full" : "disable"}"
    query += "&sslrootcert=#{URI.encode_www_form(ca)}" if ca
    "postgresql://#{user}:#{URI.encode_www_form(password)}@/#{database}?#{query}"
  end

  def main : Int32
    root_value = ENV["CARAMEL_TOOLCHAIN_ROOT"]?
    unless root_value && !root_value.empty?
      STDERR.puts "Set CARAMEL_TOOLCHAIN_ROOT to the verified contributor installation."
      return 1
    end
    installs = File.join(File.realpath(root_value), "data/installs")
    pg = File.join(installs, "conda-postgresql/18.6/bin")
    openssl = File.join(installs, "conda-openssl/3.6.4/bin/openssl")
    unless File.file?(File.join(pg, "initdb")) && File.file?(openssl)
      STDERR.puts "Managed PostgreSQL or OpenSSL is missing; rerun scripts/install-toolchain for CARAMEL_TOOLCHAIN_ROOT."
      return 1
    end
    owned = Checks.private_temp("caramel-integration-")
    data = File.join(owned, "data")
    sock = File.join(owned, "socket")
    Dir.mkdir(sock, 0o700)
    port = Checks.free_tcp_port
    env = Hash(String, String?).new
    ENV.each do |key, _|
      env[key] = nil if key.starts_with?("PG") || key.starts_with?("CARAMEL_OWNED_")
    end
    env["LC_ALL"] = "C"
    started = false
    failed = false
    begin
      required([File.join(pg, "initdb"), "-D", data, "--username=caramel_admin", "--encoding=UTF8", "--locale=C", "--auth-local=trust", "--auth-host=scram-sha-256"], env)
      {"ca", "untrusted"}.each do |name|
        required([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=Caramel integration #{name}", "-keyout", File.join(owned, "#{name}.key"), "-out", File.join(owned, "#{name}.crt")], env)
      end
      required([openssl, "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost", "-keyout", File.join(owned, "server.key"), "-out", File.join(owned, "server.csr")], env)
      File.write(File.join(owned, "server.ext"), "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n", perm: 0o600)
      required([openssl, "x509", "-req", "-in", File.join(owned, "server.csr"), "-CA", File.join(owned, "ca.crt"), "-CAkey", File.join(owned, "ca.key"), "-CAcreateserial", "-days", "1", "-extfile", File.join(owned, "server.ext"), "-out", File.join(owned, "server.crt")], env)
      File.chmod(File.join(owned, "server.key"), 0o600)
      File.open(File.join(data, "postgresql.conf"), "a") do |config|
        config << "\nlisten_addresses = '127.0.0.1'\nport = #{port}\nunix_socket_directories = '#{sock}'\nssl = on\nssl_cert_file = '#{File.join(owned, "server.crt")}'\nssl_key_file = '#{File.join(owned, "server.key")}'\ntimezone = 'UTC'\n"
      end
      required([File.join(pg, "pg_ctl"), "-D", data, "-l", File.join(owned, "postgres.log"), "-w", "start"], env)
      started = true
      password = Random::Secure.hex(24)
      sql = [
        "CREATE ROLE caramel_spec LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '#{password}';",
        "CREATE ROLE caramel_dev LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '#{password}';",
        "CREATE ROLE caramel_model_spec LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '#{password}';",
        "CREATE DATABASE caramel_spec OWNER caramel_spec;",
        "CREATE DATABASE caramel_development OWNER caramel_dev;",
        "REVOKE CONNECT ON DATABASE caramel_spec FROM PUBLIC;",
        "REVOKE CONNECT ON DATABASE caramel_development FROM PUBLIC;",
        "GRANT CONNECT ON DATABASE caramel_spec TO caramel_model_spec;",
      ].join("\n")
      required([File.join(pg, "psql"), "-X", "-v", "ON_ERROR_STOP=1", "-h", sock, "-p", port.to_s, "-U", "caramel_admin", "-d", "postgres"], env, sql)
      env["CARAMEL_OWNED_SPEC_URL"] = url("caramel_spec", "caramel_spec", password, sock, port)
      env["CARAMEL_OWNED_MODEL_RUNTIME_URL"] = url("caramel_spec", "caramel_model_spec", password, sock, port)
      env["CARAMEL_OWNED_DEV_URL"] = url("caramel_development", "caramel_dev", password, sock, port)
      env["CARAMEL_OWNED_TLS_URL"] = url("caramel_spec", "caramel_spec", password, "localhost", port, File.join(owned, "ca.crt"))
      env["CARAMEL_OWNED_WRONG_HOST_URL"] = url("caramel_spec", "caramel_spec", password, "127.0.0.1", port, File.join(owned, "ca.crt"))
      env["CARAMEL_OWNED_UNTRUSTED_URL"] = url("caramel_spec", "caramel_spec", password, "localhost", port, File.join(owned, "untrusted.crt"))
      # Superuser over the owned socket (trust), for specs that create scratch databases.
      env["CARAMEL_OWNED_ADMIN_URL"] = url("postgres", "caramel_admin", "", sock, port)
      status = Process.new([File.join(Checks::REPO, "scripts/crystal"), "spec", "spec/integration", "--error-trace"] + ARGV,
        env: env, chdir: Checks::REPO, input: Process::Redirect::Close,
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).wait
      failed = !status.success?
    rescue ex : Exception
      STDERR.puts ex.message
      failed = true
    ensure
      if started || File.exists?(File.join(data, "postmaster.pid"))
        begin
          stopped = Checks.run([File.join(pg, "pg_ctl"), "-D", data, "-m", "fast", "-w", "stop"], env: env, timeout: 30.seconds)
          if stopped.success?
            FileUtils.rm_rf(owned)
          else
            STDERR.puts "Could not stop owned PostgreSQL cluster; retained at #{owned}"
            failed = true
          end
        rescue ex
          STDERR.puts "Could not stop owned PostgreSQL cluster; retained at #{owned}: #{ex.message}"
          failed = true
        end
      else
        FileUtils.rm_rf(owned)
      end
    end
    failed ? 1 : 0
  end
end

exit Caramel::Checks::Integration.main
