require "./support/harness"

# Builds Frappé, Latte, the linter and the LatteFixture environment daemon,
# then runs the spec suite and every pass/fail check, and reports each
# result. Once the build step passes, the checks reuse its binaries
# (Checks::PREBUILT). The runs after the build step go to lanes that run side
# by side, three unless --lanes says otherwise (ADR 0022): each lane beyond
# the first uses a private toolchain prefix with its own compiler caches, and
# within a lane the runs go one after another. A failed run's full output is
# kept in a log named on its FAIL line. A release requires every run to pass.
#
#   scripts/check all [--lanes N] [--except NAME ...]
#
# --except skips a check, such as latte-daemon while your own Latte holds
# its fixed ports; a release never skips any.
module Caramel::Checks::All
  extend self

  alias Run = {String, Array(String)}

  # Performance measurements, not pass/fail checks.
  EXEMPT = %w[all compiler-profile]
  SPECS  = %w[
    spec/caramel spec/frappe spec/latte spec/sugar_orm
    spec/cold_brew spec/corretto spec/release
  ]
  USAGE = "usage: scripts/check all [--lanes N] [--except NAME ...]"
  # Lanes when --lanes is not given (ADR 0022).
  LANES = 3
  # Runs that stay on the first lane, which uses this checkout's toolchain
  # (ADR 0022): installations checks that a release reuses that toolchain,
  # editor-tools uses its editor tools, native rebuilds the installers in
  # bin/, and the `crystal spec` programs stay together.
  FIRST_LANE = %w[spec native integration latte-postgres installations editor-tools]
  # Rough seconds per run in the v0.5.0 release gate, to balance the lanes.
  # Other runs count as 6.
  WEIGHTS = {
    "frappe-project-dev" => 124, "installations" => 76, "schema-diff" => 43,
    "spec" => 25, "browser" => 23, "native" => 18, "integration" => 17,
    "latte-postgres" => 10,
  }

  @@logs : String? = nil

  def main(args : Array(String)) : Int32
    skipped = [] of String
    lanes = LANES
    rest = args.dup
    while flag = rest.shift?
      case flag
      when "--except" then skipped << (rest.shift? || Checks.fail(USAGE))
      when "--lanes"  then lanes = rest.shift?.try(&.to_i?) || Checks.fail(USAGE)
      else                 Checks.fail(USAGE)
      end
    end
    Checks.fail(USAGE) unless 1 <= lanes <= 4
    unknown = skipped - targets.map(&.first)
    Checks.fail("unknown check: #{unknown.join(", ")}") unless unknown.empty?
    prune_program_caches

    environment = File.join(Checks::REPO, "spec/fixtures/frappe_environment.cr")
    # The linter, the longest build, compiles alongside the rest: two Crystal
    # builds at a time (CONTRIBUTING.md).
    build = [script("build-lint"), "&",
             script("build-frappe"), "&&", script("build-latte"), "&&",
             script("crystal"), "build", environment, "-o", Checks::PREBUILT_ENVIRONMENT]
    runs = [{"spec", [script("crystal"), "spec"] + SPECS}] +
           targets.reject { |name, _| skipped.includes?(name) }
    failed = [] of String
    if report("build", build, nil)
      ENV[Checks::PREBUILT] = "1"
    else
      failed << "build"
      # Without the build step's binaries every check builds its own into
      # bin/, and lanes would race to write them.
      lanes = 1
    end
    failed.concat(lanes == 1 ? in_turn(runs) : side_by_side(runs, lanes))
    puts skipped.empty? ? "Ran every check." : "Skipped: #{skipped.join(", ")}"
    if failed.empty?
      puts "All #{runs.size + 1} runs passed."
      0
    else
      puts "Failed: #{failed.join(", ")}"
      1
    end
  end

  # Runs each run in turn and returns the names of the failed ones.
  private def in_turn(runs : Array(Run)) : Array(String)
    failed = [] of String
    runs.each { |(name, argv)| failed << name unless report(name, argv, nil) }
    failed
  end

  # Deals the runs to *count* lanes and runs the lanes side by side, each
  # lane's runs in turn. Returns the names of the failed runs.
  private def side_by_side(runs : Array(Run), count : Int32) : Array(String)
    lanes = plan(runs, count)
    lanes.each_with_index do |lane, index|
      toolchain = index.zero? ? " (this toolchain)" : ""
      puts "Lane #{index + 1}#{toolchain}: #{lane.map(&.first).join(", ")}"
    end
    real = File.realpath(Checks.toolchain_root)
    prefixes = (1...count).map { |index| lane_prefix(real, index + 1) }
    failed = [] of String
    done = Channel(Nil).new(count)
    lanes.each_with_index do |lane, index|
      prefix = index.zero? ? nil : prefixes[index - 1]
      env = prefix.try { |path| {"CARAMEL_TOOLCHAIN_ROOT" => path} of String => String? }
      spawn do
        lane.each { |(name, argv)| failed << name unless report(name, argv, env) }
      ensure
        done.send(nil)
      end
    end
    count.times { done.receive }
    failed
  end

  # Deals the runs to *count* lanes. FIRST_LANE's runs go to the first lane
  # before the others are dealt, heaviest first, each to the lightest lane it
  # may take: frappe-project-dev never to the first, and the timing-sensitive
  # latte-ipc last, to the lightest lane. browser goes first in its lane.
  private def plan(runs : Array(Run), count : Int32) : Array(Array(Run))
    first, rest = runs.partition { |(name, _)| FIRST_LANE.includes?(name) }
    lanes = [first] + Array.new(count - 1) { [] of Run }
    loads = [first.sum { |(name, _)| weight(name) }] + Array.new(count - 1, 0)
    sensitive, others = rest.partition { |(name, _)| name == "latte-ipc" }
    dealt = others.sort_by { |(name, _)| {-weight(name), name} } + sensitive
    dealt.each do |run|
      name = run[0]
      choices = name == "frappe-project-dev" ? (1...count).to_a : (0...count).to_a
      lane = choices.min_by { |index| loads[index] }
      lanes[lane] << run
      loads[lane] += weight(name)
    end
    lanes.map do |lane|
      browser, after = lane.partition { |(name, _)| name == "browser" }
      browser + after
    end
  end

  private def weight(name : String) : Int32
    WEIGHTS[name]? || 6
  end

  # The private toolchain prefix of lane *number*, inside this toolchain:
  # its tools through symlinks, and compiler and shards caches of its own.
  # The prefix persists, so its caches stay warm from one run to the next.
  # Its compiler sees the standard library through the prefix's path, so
  # cached objects keyed by this toolchain's paths would not match; only the
  # shards cache, keyed by repository, is cloned when the prefix is made.
  private def lane_prefix(real : String, number : Int32) : String
    lanes = File.join(real, "lanes")
    Dir.mkdir(lanes, 0o700) unless Dir.exists?(lanes)
    prefix = File.join(lanes, "lane-#{number}")
    return prefix if Dir.exists?(prefix)
    building = "#{prefix}.#{Random::Secure.hex(4)}"
    Dir.mkdir(building, 0o700)
    Dir.mkdir(File.join(building, "data"), 0o700)
    File.symlink(File.join(real, "data/installs"), File.join(building, "data/installs"))
    File.symlink(File.join(real, "bin"), File.join(building, "bin"))
    shards = File.join(real, "shards-cache")
    if Dir.exists?(shards)
      clone = Checks.run(["/bin/cp", "-cR", shards, File.join(building, "shards-cache")],
        timeout: 300.seconds)
      raise "could not clone #{shards}: #{clone.stderr}" unless clone.success?
    end
    File.rename(building, prefix)
    prefix
  end

  # Runs one step and prints its PASS or FAIL line. A failure's output, or the
  # exception that stopped it, goes to a log named on that line.
  private def report(name : String, argv : Array(String), env : Hash(String, String?)?) : Bool
    started = Time.instant
    result = begin
      run(argv, env)
    rescue ex
      ex
    end
    seconds = (Time.instant - started).total_seconds.round.to_i
    if result.is_a?(Caramel::Latte::ProcessResult) && result.success?
      puts "PASS #{name} (#{seconds} s)"
      return true
    end
    output = result.is_a?(Exception) ? result.inspect_with_backtrace : result.stdout + result.stderr
    directory = @@logs ||= Checks.private_temp("caramel-check-all-")
    log = File.join(directory, "#{name}.log")
    File.write(log, output)
    puts "FAIL #{name} (#{seconds} s): #{log}"
    false
  end

  # scripts/crystal gives each checkout program a compiler cache root of its
  # own, in this toolchain and in each lane's prefix. A root no build has
  # touched for 30 days, such as a renamed check's, is deleted before the
  # build step.
  private def prune_program_caches : Nil
    root = File.realpath(ENV["CARAMEL_TOOLCHAIN_ROOT"]? || return)
    lanes = Dir.glob(File.join(root, "lanes/lane-*/crystal-cache-programs"))
    cutoff = Time.utc - 30.days
    ([File.join(root, "crystal-cache-programs")] + lanes).each do |programs|
      next unless Dir.exists?(programs)
      Dir.each_child(programs) do |name|
        path = File.join(programs, name)
        info = File.info?(path, follow_symlinks: false) || next
        FileUtils.rm_rf(path) if info.directory? && info.modification_time < cutoff
      end
    end
  end

  # Every check in scripts/checks. frappe-project runs once, with --dev: that
  # run executes every step of the plain flow as well as its dev phase.
  private def targets : Array(Run)
    paths = Dir.glob(File.join(Checks::REPO, "scripts/checks/*.cr"))
    names = paths.map { |path| File.basename(path, ".cr").tr("_", "-") }.sort!
    plain = names - EXEMPT - ["frappe-project"]
    checks = plain.map { |name| {name, [script("check"), name]} }
    checks << {"frappe-project-dev", [script("check"), "frappe-project", "--dev"]}
    checks
  end

  private def script(name : String) : String
    File.join(Checks::REPO, "scripts", name)
  end

  # A run is `&&` chains joined by `&`. The chains run side by side; the run
  # passes when every chain does, and its output is theirs, in order.
  private def run(argv : Array(String),
                  env : Hash(String, String?)?) : Caramel::Latte::ProcessResult
    chains = argv.chunk_while { |_, word| word != "&" }.map(&.reject("&")).reject(&.empty?).to_a
    finished = Channel({Int32, Caramel::Latte::ProcessResult | Exception}).new(chains.size)
    chains.each_with_index do |chain, index|
      spawn do
        finished.send({index, run_chain(chain, env)})
      rescue ex
        finished.send({index, ex})
      end
    end
    received = Array.new(chains.size) { finished.receive }.sort_by!(&.[0])
    results = received.map do |(_, outcome)|
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
    failed = results.find { |result| !result.success? }
    status = (failed || results.last).status
    stdout = results.map(&.stdout).join
    stderr = results.map(&.stderr).join
    Caramel::Latte::ProcessResult.new(status, stdout, stderr, results.any?(&.timed_out?))
  end

  # A `&&` chain runs its commands in order and stops at the first failure.
  private def run_chain(argv : Array(String),
                        env : Hash(String, String?)?) : Caramel::Latte::ProcessResult
    commands = argv.chunk_while { |_, word| word != "&&" }.map(&.reject("&&")).reject(&.empty?)
    result = nil
    commands.each do |command|
      result = Checks.run(command, env: env, timeout: 1800.seconds)
      return result unless result.success?
    end
    result || raise "empty run"
  end
end

exit Caramel::Checks::All.main(ARGV)
