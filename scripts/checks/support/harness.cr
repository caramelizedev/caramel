require "json"
require "file_utils"
require "socket"
require "http/client"
require "digest/sha256"
require "../../../src/latte/process"
require "../../../src/latte/paths"
require "../../../src/latte/toolchain"

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

  # A git repository of this working tree, committed and tagged
  # v<version>, standing in for github.com/caramelizedev/caramel. Its
  # shard.yml declares *version*.
  def self.tagged_repository(destination : String, version : String) : String
    listing = %w[ls-files -z --cached --others --exclude-standard]
    listed = run(["/usr/bin/git", "-C", REPO] + listing).stdout
    listed.split('\0', remove_empty: true).each do |relative|
      source = File.join(REPO, relative)
      next unless File.file?(source)
      Dir.mkdir_p(File.dirname(File.join(destination, relative)))
      File.copy(source, File.join(destination, relative))
    end
    manifest = File.join(destination, "shard.yml")
    lines = File.read_lines(manifest).map do |line|
      line.starts_with?("version:") ? "version: #{version}" : line
    end
    File.write(manifest, lines.join('\n') + '\n')
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
