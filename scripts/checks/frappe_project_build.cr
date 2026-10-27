require "./support/project_fixture"

module Caramel::Checks
  # ADR 0032 end to end: frappe build refuses uncommitted changes, compiles the
  # committed tree in a container into an artifact whose binary runs on a
  # stock Ubuntu, boots that artifact against PostgreSQL over TLS, and the
  # native binary serves as a production process would. Its own application,
  # so it runs beside frappe-project rather than after it.
  class FrappeProjectBuild < ProjectFixture
    def initialize
      super("caramel-frappe-build-")
    end

    def execute(args : Array(String)) : Nil
      puts "Frappé build fixture: #{@root}"
      # ameba:disable Lint/UselessAssign -- read by the ensure below
      failed = true
      begin
        start
        command([@frappe, "new", "bookshelf"], chdir: @projects)
        values = local_values(@project)
        make = [@frappe, "make", "resource", "Book", "title:string", "author:string"]
        command(make, chdir: @project)
        write_probe
        migrated = command([@frappe, "migrate"], chdir: @project)
        assert!(migrated.stdout.includes?(MATCHED), migrated.stdout)
        release_build
        production_serve(values)
        failed = false
      ensure
        finish(failed)
      end
    end

    private def release_build : Nil
      docker = Process.find_executable("docker") || "/usr/local/bin/docker"
      engine = File.executable?(docker) && attempt([docker, "info"], timeout: 60.seconds).success?
      unless engine
        puts "SKIP: frappe build needs a running container engine"
        return
      end
      git = ["/usr/bin/git", "-C", @project, "-c", "user.name=Caramel",
             "-c", "user.email=checks@caramel.invalid", "-c", "commit.gpgsign=false"]
      command(git + ["init", "-q"], echo: false)
      command(git + ["add", "-A"], echo: false)
      command(git + ["commit", "-qm", "build"], echo: false)
      dirty = File.join(@project, "dirty.txt")
      File.write(dirty, "uncommitted\n")
      refused = attempt([@frappe, "build"], chdir: @project, timeout: 60.seconds)
      reported = refused.status.exit_code == 1 && refused.stderr.includes?("uncommitted changes")
      assert!(reported, refused.stdout + refused.stderr)
      File.delete(dirty)
      built = attempt([@frappe, "build"], chdir: @project, timeout: 1200.seconds)
      assert!(built.success?, built.stdout + built.stderr)
      artifact = built.stdout.chomp
      name = /\Abookshelf-\d{8}T\d{6}Z-[0-9a-f]{7}-linux-amd64\.tar\.gz\z/
      named = !artifact.includes?('\n') && artifact.starts_with?('/') &&
              File.file?(artifact) && File.basename(artifact).matches?(name)
      assert!(named, built.stdout)
      listing = command(["/usr/bin/tar", "-tzf", artifact], echo: false).stdout.lines
      packed = listing.includes?("bin/bookshelf") && listing.any?(&.starts_with?("public/"))
      assert!(packed, listing.join('\n'))
      only_both = listing.all? { |entry| %w[bin/ public/].any? { |top| entry.starts_with?(top) } }
      assert!(only_both, listing.join('\n'))
      sidecars(artifact)
      unpacked = File.join(@root, "release")
      Dir.mkdir(unpacked, 0o755)
      command(["/usr/bin/tar", "-xzf", artifact, "-C", unpacked], echo: false)
      ubuntu = [docker, "run", "--rm", "--platform", "linux/amd64", "-v", "#{unpacked}:/r:ro",
                "ubuntu:24.04", "/r/bin/bookshelf", "routes"]
      routes = attempt(ubuntu, timeout: 600.seconds)
      health = routes.success? && routes.stdout.lines.any?(&.matches?(/^GET\s+\/health\s/))
      assert!(health, routes.stdout + routes.stderr)
      probe = routes.stdout.lines.any?(&.matches?(/^POST\s+\/probe\/jobs\s/))
      assert!(probe, routes.stdout)
      puts "PASS: frappe build writes a static linux/amd64 artifact, GMP linked in, " \
           "that runs on Ubuntu"
      ProductionArtifact.new(self, docker, unpacked).check
    end

    # The checksum verifies the tarball and the SBOM names what it links.
    private def sidecars(artifact : String) : Nil
      checksum = artifact + ".sha256"
      sbom = artifact + ".sbom.json"
      assert!(File.file?(checksum) && File.file?(sbom), "missing #{checksum} or #{sbom}")
      verify = ["/usr/bin/shasum", "-a", "256", "-c", File.basename(checksum)]
      verified = attempt(verify, chdir: File.dirname(artifact), timeout: 60.seconds)
      expected = "#{File.basename(artifact)}: OK\n"
      assert!(verified.success? && verified.stdout == expected, verified.stdout + verified.stderr)
      document = JSON.parse(File.read(sbom))
      assert!(document["bomFormat"] == "CycloneDX" && document["specVersion"] == "1.5", sbom)
      components = document["components"].as_a
      versions = components.to_h { |entry| {entry["name"].as_s, entry["version"].as_s} }
      caramel = versions["caramel"]? || ""
      openssl = versions["openssl"]? || ""
      assert!(caramel.matches?(/\A\d/) && openssl.matches?(/\A\d/), File.read(sbom))
      puts "PASS: frappe build writes a checksum and an SBOM that names " \
           "caramel #{caramel} and openssl #{openssl}"
    end

    # Runs the binary as a server would: on a socket of its own, serving public
    # files from CARAMEL_ROOT rather than the project it was built from, and
    # leaving jobs and schedules to a separate `work` process.
    private def production_serve(values : Hash(String, String)) : Nil
      directory = File.join(@root, "production")
      Dir.mkdir(directory, 0o700)
      socket = File.join(directory, "app.sock")
      ops_socket = File.join(directory, "app.ops.sock")
      release = File.join(@root, "production-root")
      Dir.mkdir(release, 0o700)
      copy = ["/bin/cp", "-R", File.join(@project, "public"), File.join(release, "public")]
      command(copy, echo: false)
      File.write(File.join(release, "public/marker.txt"), "production root\n")
      settings = {
        "CARAMEL_ENV"       => "development",
        "CARAMEL_SOCKET"    => socket,
        "CARAMEL_ROOT"      => release,
        "CARAMEL_POOL_SIZE" => "7",
      }
      binary = File.join(@project, ".caramel/application")
      process = Process.new(binary, ["serve", "--no-workers"],
        chdir: @root, env: environment(values.merge(settings)),
        output: @app_log, error: @app_log)
      begin
        started = Checks.wait_until(10.seconds, 50.milliseconds) do
          (File.exists?(socket) && File.exists?(ops_socket)) || process.terminated?
        end
        assert!(started && File.exists?(ops_socket), "serve did not open its production sockets")
        status, body = unix_get(socket, "/marker.txt", "bookshelf.caramel")
        assert!(status == 200 && body == "production root\n", "#{status}: #{body}")
        key = File.read(ops_socket + ".key").strip
        status, body = unix_get(ops_socket, "/v1/status", "ops", key)
        document = JSON.parse(body)
        idle = status == 200 && document["workers"].as_a.empty? &&
               document["scheduler"].as_s == "off"
        assert!(idle, "#{status}: #{body}")
        web = document["pools"].as_a.find { |pool| pool["name"].as_s == "web" }
        assert!(!web.nil? && web["max"].as_i == 7, "#{status}: #{body}")
      ensure
        Checks.stop(process, 30.seconds)
      end
      assert!(!File.exists?(socket), "serve left #{socket} behind")
      puts "PASS: serve reads public files from CARAMEL_ROOT"
      puts "PASS: serve --no-workers runs no workers or schedules"
      puts "PASS: serve sizes its web pool from CARAMEL_POOL_SIZE"
    end

    private def unix_get(socket : String, path : String, host : String,
                         bearer : String? = nil) : {Int32, String}
      connection = Socket.unix
      connection.connect(Socket::UNIXAddress.new(socket), timeout: 5.seconds)
      client = HTTP::Client.new(connection, host)
      headers = HTTP::Headers{"Host" => host, "Connection" => "close"}
      headers["Authorization"] = "Bearer #{bearer}" if bearer
      response = client.get(path, headers)
      {response.status_code, response.body}
    ensure
      client.try &.close
    end
  end
end

require "./frappe_project_build/production_artifact"

begin
  Caramel::Checks::FrappeProjectBuild.new.execute(ARGV)
rescue ex
  STDERR.puts ex.message
  exit 1
end
