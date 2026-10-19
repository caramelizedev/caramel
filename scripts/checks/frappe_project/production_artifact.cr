require "http/client"
require "random/secure"

module Caramel::Checks
  # ADR 0032 end to end on Linux: the artifact prints its roles with `db roles`,
  # migrates and serves over verify-full TLS to PostgreSQL in a container,
  # answers on its socket, and exits 0 on SIGTERM.
  class FrappeProject::ProductionArtifact
    FAILED   = "production artifact assertion failed"
    POSTGRES = "postgres:18-alpine"
    UBUNTU   = "ubuntu:24.04"
    DATABASE = "bookshelf"
    OWNER    = "bookshelf_owner"
    RUNTIME  = "bookshelf_web"
    HOST     = "bookshelf.caramel"
    SOCKET   = "/run/app/app.sock"

    # PostgreSQL reads its key only when the postgres user owns it with mode 0600.
    POSTGRES_START = <<-SH
      install -o postgres -g postgres -m 0644 /certs/server.crt /tmp/server.crt
      install -o postgres -g postgres -m 0600 /certs/server.key /tmp/server.key
      exec docker-entrypoint.sh postgres -c ssl=on \
        -c ssl_cert_file=/tmp/server.crt -c ssl_key_file=/tmp/server.key
      SH

    # A GET over the app's socket from inside its container, which has perl-base
    # but no curl. Prints the raw response; exits 7 while the socket is missing.
    HTTP_GET = <<-'PERL'
      use IO::Socket::UNIX;
      my ($path, $target, $host) = @ARGV;
      my $socket = IO::Socket::UNIX->new(Peer => $path) or exit 7;
      print $socket "GET $target HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n";
      print while <$socket>;
      PERL

    TLS_SESSIONS = <<-SQL
      SELECT count(*) FILTER (WHERE ssl) || '|' || count(*) FILTER (WHERE NOT ssl)
      FROM pg_stat_ssl JOIN pg_stat_activity USING (pid)
      WHERE usename = '#{RUNTIME}'
      SQL

    def initialize(@fixture : FrappeProject, @docker : String, @unpacked : String)
      suffix = Random::Secure.hex(4)
      @network = "caramel-check-#{suffix}"
      @postgres = "caramel-check-postgres-#{suffix}"
      @app = "caramel-check-app-#{suffix}"
      @certs = File.join(@fixture.root, "artifact-tls")
      @superuser_password = Random::Secure.hex(24)
      @owner_password = Random::Secure.hex(24)
      @runtime_password = Random::Secure.hex(24)
      @secret = Random::Secure.hex(32)
    end

    def check : Nil
      begin
        issue_certificates
        start_postgres
        create_roles
        migrate
        serve
        assert_serving
        assert_tls
        assert_drained
      ensure
        # --volumes: the PostgreSQL image declares an anonymous data volume.
        @fixture.attempt([@docker, "rm", "--force", "--volumes", @app, @postgres])
        @fixture.attempt([@docker, "network", "rm", @network])
      end
      puts "PASS: the linux/amd64 artifact creates its roles, migrates and serves over " \
           "verify-full TLS to PostgreSQL, and exits 0 on SIGTERM"
    end

    private def assert!(condition : Bool, message : String = FAILED) : Nil
      @fixture.assert!(condition, message)
    end

    private def issue_certificates : Nil
      Dir.mkdir(@certs, 0o755)
      installs = File.join(File.realpath(Checks.toolchain_root), "data/installs")
      openssl = File.join(installs, "conda-openssl/3.6.4/bin/openssl")
      path = ->(name : String) { File.join(@certs, name) }
      @fixture.command([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=Caramel artifact check ca",
                        "-keyout", path.call("ca.key"), "-out", path.call("ca.crt")],
        echo: false)
      @fixture.command([openssl, "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=postgres",
                        "-keyout", path.call("server.key"), "-out", path.call("server.csr")],
        echo: false)
      # Each text ends with a newline, the blank line before its terminator.
      File.write(path.call("server.ext"), <<-EXT, perm: 0o600)
        subjectAltName=DNS:postgres
        extendedKeyUsage=serverAuth

        EXT
      @fixture.command([openssl, "x509", "-req", "-in", path.call("server.csr"),
                        "-CA", path.call("ca.crt"), "-CAkey", path.call("ca.key"),
                        "-CAcreateserial", "-days", "1",
                        "-extfile", path.call("server.ext"),
                        "-out", path.call("server.crt")],
        echo: false)
      # The container's root copies the key; the fixture root is private and the
      # key lasts one day.
      File.chmod(path.call("server.key"), 0o644)
    end

    private def start_postgres : Nil
      @fixture.command([@docker, "network", "create", @network], echo: false)
      # The timeout allows for pulling the image.
      @fixture.command([@docker, "run", "-d", "--name", @postgres, "--network", @network,
                        "--network-alias", "postgres",
                        "-e", "POSTGRES_PASSWORD=#{@superuser_password}",
                        "-v", "#{@certs}:/certs:ro", POSTGRES, "sh", "-euc", POSTGRES_START],
        echo: false, timeout: 600.seconds)
      # The image's init server listens on no TCP address, so TCP readiness
      # means the final server is up.
      probe = [@docker, "exec", @postgres, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"]
      ready = Checks.wait_until(90.seconds, 500.milliseconds) { @fixture.attempt(probe).success? }
      assert!(ready, "PostgreSQL did not start:\n#{logs(@postgres)}")
    end

    private def create_roles : Nil
      script = artifact(["db", "roles", DATABASE, OWNER, RUNTIME]).stdout
      script += "ALTER ROLE #{OWNER} PASSWORD '#{@owner_password}';\n"
      script += "ALTER ROLE #{RUNTIME} PASSWORD '#{@runtime_password}';\n"
      @fixture.command([@docker, "exec", "-i", @postgres, "psql", "-X", "-q",
                        "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"],
        input: script, echo: false)
    end

    private def migrate : Nil
      result = artifact(["migrate"], {"MIGRATION_DATABASE_URL" => url(OWNER, @owner_password)})
      applied = result.stdout.matches?(/^Applied [1-9]\d* migrations\.$/m)
      assert!(applied, result.stdout + result.stderr)
    end

    # With CARAMEL_ENV unset the binary runs as production. `exec` makes `serve`
    # PID 1, so `docker stop` signals it.
    private def serve : Nil
      @fixture.command([@docker, "run", "-d", "--name", @app, "--platform", "linux/amd64",
                        "--network", @network,
                        "-v", "#{@unpacked}:/r:ro", "-v", "#{@certs}:/certs:ro",
                        "-e", "DATABASE_URL=#{url(RUNTIME, @runtime_password)}",
                        "-e", "APP_ORIGIN=https://#{HOST}",
                        "-e", "APP_SECRET=#{@secret}",
                        "-e", "CARAMEL_SOCKET=#{SOCKET}",
                        "-e", "CARAMEL_ROOT=/r",
                        UBUNTU, "sh", "-euc",
                        "mkdir -m 700 /run/app && exec /r/bin/bookshelf serve --no-workers"],
        echo: false, timeout: 120.seconds)
    end

    private def assert_serving : Nil
      health = nil
      answered = Checks.wait_until(120.seconds, 500.milliseconds) do
        health = get("/health")
        health.try(&.status_code) == 200
      end
      assert!(answered && health.try(&.body) == "ok", "GET /health failed:\n#{logs(@app)}")
      # The binary runs with CARAMEL_ENV unset, which is production.
      hsts = health.try(&.headers["Strict-Transport-Security"]?)
      assert!(hsts == "max-age=31536000", "Strict-Transport-Security: #{hsts.inspect}")
      # The central resource index reads PostgreSQL as the runtime role.
      status = get("/tags").try(&.status_code)
      assert!(status == 200, "GET /tags: #{status}\n#{logs(@app)}")
      # The artifact's public/ files, found through CARAMEL_ROOT.
      status = get("/assets/htmx-4.0.0.min.js").try(&.status_code)
      assert!(status == 200, "GET /assets/htmx-4.0.0.min.js: #{status}\n#{logs(@app)}")
    end

    private def assert_tls : Nil
      result = @fixture.command([@docker, "exec", @postgres, "psql", "-X", "-At",
                                 "-U", "postgres", "-d", "postgres", "-c", TLS_SESSIONS],
        echo: false)
      encrypted, plain = result.stdout.strip.split('|').map(&.to_i?)
      assert!(!encrypted.nil? && !plain.nil? && encrypted > 0 && plain == 0,
        "runtime sessions (encrypted|plain): #{result.stdout}")
    end

    private def assert_drained : Nil
      @fixture.command([@docker, "stop", "--time", "30", @app], echo: false, timeout: 60.seconds)
      inspect = [@docker, "inspect", "--format", "{{.State.ExitCode}}", @app]
      code = @fixture.command(inspect, echo: false).stdout.strip
      assert!(code == "0", "serve exited #{code} after SIGTERM:\n#{logs(@app)}")
    end

    private def artifact(arguments : Array(String),
                         environment = {} of String => String) : Caramel::Latte::ProcessResult
      flags = [] of String
      environment.each { |key, value| flags.concat(["-e", "#{key}=#{value}"]) }
      @fixture.command([@docker, "run", "--rm", "--platform", "linux/amd64",
                        "--network", @network,
                        "-v", "#{@unpacked}:/r:ro", "-v", "#{@certs}:/certs:ro"] +
                       flags + [UBUNTU, "/r/bin/bookshelf"] + arguments,
        echo: false, timeout: 600.seconds)
    end

    private def url(role : String, password : String) : String
      "postgresql://#{role}:#{password}@postgres:5432/#{DATABASE}" \
      "?sslmode=verify-full&sslrootcert=/certs/ca.crt"
    end

    private def get(path : String) : HTTP::Client::Response?
      result = @fixture.attempt([@docker, "exec", @app, "perl", "-e", HTTP_GET, SOCKET, path, HOST],
        timeout: 30.seconds)
      return unless result.success?
      HTTP::Client::Response.from_io?(IO::Memory.new(result.stdout))
    rescue
      # A server that closes or truncates a response during startup is not up yet.
      nil
    end

    private def logs(name : String) : String
      result = @fixture.attempt([@docker, "logs", name])
      result.stdout + result.stderr
    end
  end
end
