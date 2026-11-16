require "json"
require "file_utils"
require "socket"
require "http/client"
require "digest/sha256"
require "../../../src/latte/process"
require "../../../src/latte/paths"
require "../../../src/latte/toolchain"
require "../../../src/frappe/published"

module Caramel::Checks
  REPO = File.expand_path("../../..", __DIR__)

  # A check and every tool it starts use one toolchain, resolved the way
  # Frappé resolves it: CARAMEL_TOOLCHAIN_ROOT, else .caramel-toolchain.
  if located = Caramel::Latte::Toolchain.locate(REPO)
    ENV["CARAMEL_TOOLCHAIN_ROOT"] = located[0]
  end

  # scripts/check all sets this once its build step has passed. The checks it
  # then runs use that step's binaries instead of rebuilding them from the
  # same tree; a check run on its own builds what it needs.
  PREBUILT = "CARAMEL_CHECK_ALL_BUILT"

  # The LatteFixture environment daemon (spec/fixtures/frappe_environment.cr)
  # that the build step builds.
  PREBUILT_ENVIRONMENT = File.join(REPO, "bin/checks/frappe-environment")

  # scripts/check all sets this to the directory that holds its one assembly of the
  # published shards, which every lane's checks share; a check run on its own
  # assembles them itself.
  PUBLISHED = "CARAMEL_CHECK_ALL_PUBLISHED"

  # Where an assembly records its shards, for the checks that share it.
  ASSEMBLED = "shards.json"

  # An assembled shard as ASSEMBLED records it.
  alias Assembled = NamedTuple(
    name: String,
    repository: String,
    version: String,
    commit: String,
    directory: String)

  # A command's stdout and stderr are each captured up to 16 MiB.
  OUTPUT_LIMIT = 16 * 1024 * 1024

  def self.prebuilt? : Bool
    ENV[PREBUILT]? == "1"
  end

  def self.run(argv : Array(String), *,
               chdir : String = REPO,
               env : Hash(String, String?)? = nil,
               clear_env : Bool = false,
               input : String? = nil,
               timeout : Time::Span = 90.seconds) : Caramel::Latte::ProcessResult
    Caramel::Latte::ProcessRunner.run(argv,
      chdir: chdir,
      env: env,
      clear_env: clear_env,
      input: input,
      timeout: timeout,
      output_limit: OUTPUT_LIMIT)
  end

  def self.crystal(args : Array(String), **options)
    run([File.join(REPO, "scripts/crystal")] + args, **options)
  end

  # Type-checks each source (`crystal build SOURCE --no-codegen`) and returns
  # the results in order. The first runs alone, so it builds any macro-run
  # helper that the others then reuse; the rest run *workers* at a time. Type
  # checks create no program cache directory and run no cache cleanup, so
  # they may overlap (CONTRIBUTING.md).
  def self.type_check(sources : Array(String),
                      workers : Int32 = 4) : Array(Caramel::Latte::ProcessResult)
    check = ->(source : String) { crystal(["build", source, "--no-codegen"], timeout: 90.seconds) }
    return sources.map { |source| check.call(source) } if sources.size < 2
    results = Array(Caramel::Latte::ProcessResult?).new(sources.size, nil)
    results[0] = check.call(sources[0])
    queue = Channel(Int32).new(sources.size)
    (1...sources.size).each { |index| queue.send(index) }
    queue.close
    done = Channel(Exception?).new(workers)
    workers.times do
      spawn do
        while index = queue.receive?
          results[index] = check.call(sources[index])
        end
        done.send(nil)
      rescue ex
        done.send(ex)
      end
    end
    failures = Array.new(workers) { done.receive }.compact
    raise failures.first unless failures.empty?
    results.map(&.not_nil!)
  end

  def self.shards(args : Array(String), **options)
    run([File.join(REPO, "scripts/shards")] + args, **options)
  end

  def self.fail(message : String) : NoReturn
    STDERR.puts message
    exit 1
  end

  def self.toolchain_root : String
    root = ENV["CARAMEL_TOOLCHAIN_ROOT"]?
    return root if root && !root.empty?
    fail("No Caramel toolchain is installed for #{REPO}. Run scripts/install-toolchain.")
  end

  def self.private_temp(prefix : String) : String
    path = File.tempname(prefix, dir: "/private/tmp")
    Dir.mkdir(path, 0o700)
    path
  end

  # Where checks that generate applications keep their roots: one fixed path
  # per checkout and check, so the generated programs' compiler caches
  # persist from run to run (scripts/crystal gives a program under here a
  # cache root of its own), and two checkouts never share one.
  CHECK_ROOTS = "/private/tmp/caramel-checks"

  @@check_locks = [] of File

  # The fixed root for *prefix*, emptied, held by a lock for the life of
  # this process. A run that finds the lock held fails at once rather than
  # disturbing the run that holds it. With the lock free, a process a
  # crashed run left behind in the root is stopped before the root is
  # emptied, so its sockets do not collide with this run's.
  def self.check_root(prefix : String) : String
    checkout = Digest::SHA256.hexdigest(File.realpath(REPO))[0, 8]
    parent = File.join(CHECK_ROOTS, checkout)
    Dir.mkdir_p(parent, 0o700)
    path = File.join(parent, prefix.rchop("-"))
    lock = File.open("#{path}.lock", "w")
    begin
      lock.flock_exclusive(blocking: false)
    rescue IO::Error
      lock.close
      fail("Another check is using #{path}; wait for it to finish")
    end
    @@check_locks << lock
    if Dir.exists?(path)
      run(["/usr/bin/pkill", "-TERM", "-f", "#{path}/"], timeout: 5.seconds)
      gone = wait_until(5.seconds, 100.milliseconds) do
        !run(["/usr/bin/pgrep", "-f", "#{path}/"], timeout: 5.seconds).success?
      end
      run(["/usr/bin/pkill", "-KILL", "-f", "#{path}/"], timeout: 5.seconds) unless gone
      FileUtils.rm_rf(path)
    end
    Dir.mkdir(path, 0o700)
    path
  end

  # A git repository of this working tree, committed and tagged
  # v<version>, standing in for github.com/caramelizedev/caramel. Its
  # manifests state *version* as scripts/release stamps it: the framework's,
  # and the sweettalk shard's with the framework it asks for.
  def self.tagged_repository(destination : String, version : String) : String
    listing = %w[ls-files -z --cached --others --exclude-standard]
    listed = run(["/usr/bin/git", "-C", REPO] + listing).stdout
    listed.split('\0', remove_empty: true).each do |relative|
      source = File.join(REPO, relative)
      next unless File.file?(source)
      Dir.mkdir_p(File.dirname(File.join(destination, relative)))
      File.copy(source, File.join(destination, relative))
    end
    stated = {"shard.yml" => /\Aversion:/, "sweettalk/shard.yml" => /\A *version:/}
    stated.each do |name, line_of_version|
      manifest = File.join(destination, name)
      lines = File.read_lines(manifest).map do |line|
        line.matches?(line_of_version) ? line.sub(/version:.*/, "version: #{version}") : line
      end
      File.write(manifest, lines.join('\n') + '\n')
    end
    git = ["/usr/bin/git", "-C", destination,
           "-c", "user.name=Caramel checks",
           "-c", "user.email=checks@caramel.invalid"]
    steps = [
      ["init", "--quiet"],
      ["add", "--all"],
      ["commit", "--quiet", "--message", "Caramel #{version}"],
      ["tag", "v#{version}"],
    ]
    steps.each do |arguments|
      result = run(git + arguments)
      fail(result.stdout + result.stderr) unless result.success?
    end
    destination
  end

  # Assembles the shards this working tree publishes (published.yml) into *directory*,
  # each a git repository that holds what a release would publish, records them there
  # for `published` and returns them by name.
  def self.assemble(directory : String) : Hash(String, Frappe::Published::Shard)
    shards = Frappe::Published.assemble(REPO, directory)
    recorded = shards.values.map do |shard|
      {name: shard.name, repository: shard.repository, version: shard.version,
       commit: shard.commit, directory: shard.directory}
    end
    File.write(File.join(directory, ASSEMBLED), recorded.to_json)
    shards
  rescue ex : Frappe::Error
    fail("The published shards do not assemble: #{ex.message}")
  end

  # The published shards by name: the ones scripts/check all assembled for this run,
  # else an assembly of this check's own in *directory*.
  def self.published(directory : String) : Hash(String, Frappe::Published::Shard)
    shared = ENV[PUBLISHED]? || return assemble(directory)
    recorded = Array(Assembled).from_json(File.read(File.join(shared, ASSEMBLED)))
    recorded.to_h { |shard| {shard[:name], Frappe::Published::Shard.new(**shard)} }
  end

  # Where Shards fetches an assembled shard from: its repository on this machine.
  def self.source(shard : Frappe::Published::Shard) : String
    "file://#{shard.directory}"
  end

  # Every regular file under *directory* but git's own, by path, with the digest of
  # its bytes.
  def self.tree(directory : String) : Hash(String, String)
    git = File.join(directory, ".git", "")
    paths = Dir.glob(File.join(directory, "**/*"), match: :dot_files).select do |path|
      !path.starts_with?(git) && File.info(path, follow_symlinks: false).file?
    end
    paths.sort!.to_h do |path|
      {path.lchop("#{directory}/"), Digest::SHA256.hexdigest(File.read(path))}
    end
  end

  # Raises unless the application at *project* holds *shard* as a release publishes it:
  # lib/<name> is a copy of its tree, file for file, and shard.lock pins its commit.
  def self.installed!(project : String, shard : Frappe::Published::Shard) : Nil
    library = File.join(project, "lib", shard.name)
    copied = File.info?(library, follow_symlinks: false).try(&.directory?)
    unless copied && tree(library) == tree(shard.directory)
      raise "#{library} is not the published tree of #{shard.name}"
    end
    lock = YAML.parse(File.read(File.join(project, "shard.lock")))
    locked = lock["shards"][shard.name]["version"].as_s
    return if locked == shard.pin
    raise "#{project}/shard.lock locks #{shard.name} #{locked}, not #{shard.pin}"
  end

  # A stand-in for this checkout at *directory*, whose framework and sweettalk shard
  # are the published ones: *shards*' caramel tree at its root and their sweettalk
  # tree in sweettalk/, as the repository lays them out, beside this checkout's
  # installed dependencies and its *files* at their own paths. A program among them
  # that requires `../../src/caramel` compiles against what a release publishes, and
  # reaches nothing else of the checkout.
  def self.published_checkout(directory : String,
                              shards : Hash(String, Frappe::Published::Shard),
                              files : Array(String)) : String
    targets = {"caramel" => directory, "sweettalk" => File.join(directory, "sweettalk")}
    targets.each do |name, target|
      clone = run(["/usr/bin/git", "clone", "--quiet", shards[name].directory, target])
      fail(clone.stdout + clone.stderr) unless clone.success?
    end
    File.symlink(File.join(REPO, "lib"), File.join(directory, "lib"))
    files.each do |file|
      Dir.mkdir_p(File.dirname(File.join(directory, file)))
      File.copy(File.join(REPO, file), File.join(directory, file))
    end
    directory
  end

  def self.runtime_root(state_root : String) : String
    Caramel::Latte::StateSecurity.runtime_root(File.realpath(state_root))
  end

  def self.free_tcp_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.port
  ensure
    server.try &.close
  end

  def self.free_udp_port : Int32
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    socket.local_address.port
  ensure
    socket.try &.close
  end

  def self.wait_until(timeout : Time::Span, interval : Time::Span, & : -> Bool) : Bool
    deadline = Time.instant + timeout
    loop do
      return true if yield
      return false if Time.instant >= deadline
      sleep interval
    end
  end

  def self.stop(process : Process, grace : Time::Span = 5.seconds) : Nil
    unless process.terminated?
      process.terminate
      unless wait_until(grace, 50.milliseconds) { process.terminated? }
        process.terminate(graceful: false)
      end
    end
    process.wait
  rescue
    begin
      process.terminate(graceful: false)
      process.wait
    rescue
    end
  end

  def self.gone?(pid : Int64) : Bool
    result = run(["/bin/ps", "-p", pid.to_s, "-o", "stat="], timeout: 5.seconds)
    state = result.stdout.strip
    state.empty? || state.starts_with?('Z')
  end
end
