require "./support/harness"

# Builds Frappé, Latte, the linter and the LatteFixture environment daemon,
# then runs the spec suite and every pass/fail check, and reports each
# result. Once the build step passes, the checks reuse its binaries
# (Checks::PREBUILT). The runs after the build step go to lanes that run side
# by side, as many as the machine's cores and memory allow unless --lanes
# says otherwise (ADR 0022): each lane beyond the first uses a private
# toolchain prefix with its own compiler caches, and within a lane the runs
# go one after another. The lanes are balanced by the durations the last
# run recorded on this machine, and each prints its total and longest run.
# A failed run's full output is kept in a log named on its FAIL line. A
# release requires every run to pass.
#
#   scripts/check all [--lanes N] [--except NAME ...]
#
# --except skips a check, such as latte-daemon while your own Latte holds
# its fixed ports; a release never skips any.
module Caramel::Checks::All
  extend self

  alias Run = {String, Array(String)}

  # What a run took the last time it passed on this machine, and the lane it
  # ran on: a run keeps its lane while loads allow, so its compiler cache
  # there stays warm.
  record Record, seconds : Int32, lane : Int32 do
    include JSON::Serializable
  end

  # Performance measurements, not pass/fail checks.
  EXEMPT = %w[all compiler-profile]
  SPECS  = %w[
    spec/caramel spec/frappe spec/latte spec/sugar_orm
    spec/cold_brew spec/corretto spec/release
  ]
  USAGE = "usage: scripts/check all [--lanes N] [--except NAME ...]"
  # The most lanes --lanes takes, and the default's ceiling (ADR 0022).
  MAX_LANES = 8
  # Where the toolchain root keeps the runs' durations and lanes.
  DURATIONS = "check-durations.json"
  # One gate per machine: a second check all, from any checkout, would share
  # the cores, the toolchain caches and the Latte ports with the first and
  # spoil both. The lock names its holder for the run that is refused.
  GATE = "/private/tmp/caramel-gate.lock"
  # Runs that stay on the first lane, which uses this checkout's toolchain
  # (ADR 0022): installations checks that a release reuses that toolchain,
  # editor-tools uses its editor tools, and native rebuilds the installers
  # in bin/.
  FIRST_LANE = %w[native installations editor-tools]
  # Seconds per run on a 12-core Apple Silicon Mac in 2026-10, used to balance
  # the lanes until this machine has recorded its own. Other runs count as 6.
  WEIGHTS = {
    "frappe-project" => 298, "frappe-project-build" => 216, "frappe-project-dev" => 146,
    "installations" => 91, "schema-diff" => 83, "integration" => 72, "page-boxoffice" => 55,
    "page-forms" => 50, "page-json" => 47, "browser" => 44, "page-jobs" => 37,
    "page-webhooks" => 32, "page-sums" => 45, "spec" => 66, "native" => 22, "editor-tools" => 22,
    "latte-postgres" => 15,
  }

  @@logs : String? = nil
  @@records = {} of String => Record

  def main(args : Array(String)) : Int32
    skipped = [] of String
    lanes, cores, gigabytes = default_lanes
    chosen = false
    rest = args.dup
    while flag = rest.shift?
      case flag
      when "--except" then skipped << (rest.shift? || Checks.fail(USAGE))
      when "--lanes"
        lanes = rest.shift?.try(&.to_i?) || Checks.fail(USAGE)
        chosen = true
      else Checks.fail(USAGE)
      end
    end
    Checks.fail(USAGE) unless 1 <= lanes <= MAX_LANES
    memory = gigabytes ? ", #{gigabytes} GB" : ""
    puts "Lanes: #{lanes}#{chosen ? "" : " (#{cores} cores#{memory})"}"
    hold_gate
    @@records = read_records
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
    if report("build", build, nil)[0]
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
    passed = {} of String => Record
    failed = {} of String => Int32
    runs.each do |(name, argv)|
      ok, seconds = report(name, argv, nil)
      if ok
        passed[name] = Record.new(seconds, 0)
      else
        failed[name] = seconds
      end
    end
    summarize(0, runs.map(&.first), passed, failed)
    write_records(passed)
    failed.keys
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
    passed = {} of String => Record
    failed = {} of String => Int32
    done = Channel(Nil).new(count)
    lanes.each_with_index do |lane, index|
      prefix = index.zero? ? nil : prefixes[index - 1]
      env = prefix.try { |path| {"CARAMEL_TOOLCHAIN_ROOT" => path} of String => String? }
      spawn do
        lane.each do |(name, argv)|
          ok, seconds = report(name, argv, env)
          if ok
            passed[name] = Record.new(seconds, index)
          else
            failed[name] = seconds
          end
        end
      ensure
        done.send(nil)
      end
    end
    count.times { done.receive }
    lanes.each_with_index { |lane, index| summarize(index, lane.map(&.first), passed, failed) }
    write_records(passed)
    failed.keys
  end

  # Deals the runs to *count* lanes. FIRST_LANE's runs go to the first lane
  # before the others are dealt, heaviest first, each to the lightest lane,
  # and the timing-sensitive latte-ipc last. A run stays on the lane it last
  # ran on while that lane is no further above the lightest lane's load than
  # the run's own duration: a move costs a cold compile in the new lane's
  # prefix, which doubled a spec-heavy run, and can only save that much
  # imbalance. browser goes first in its lane.
  private def plan(runs : Array(Run), count : Int32) : Array(Array(Run))
    first, rest = runs.partition { |(name, _)| FIRST_LANE.includes?(name) }
    lanes = [first] + Array.new(count - 1) { [] of Run }
    loads = [first.sum { |(name, _)| weight(name) }] + Array.new(count - 1, 0)
    sensitive, others = rest.partition { |(name, _)| name == "latte-ipc" }
    dealt = others.sort_by { |(name, _)| {-weight(name), name} } + sensitive
    dealt.each do |run|
      name = run[0]
      lightest = loads.min
      lane = (0...count).min_by { |index| loads[index] }
      if (previous = @@records[name]?.try(&.lane)) && previous < count
        lane = previous if loads[previous] - lightest <= weight(name)
      end
      lanes[lane] << run
      loads[lane] += weight(name)
    end
    lanes.map do |lane|
      browser, after = lane.partition { |(name, _)| name == "browser" }
      browser + after
    end
  end

  # Seconds the run took the last time it passed on this machine, else the
  # constant for its name, else 6.
  private def weight(name : String) : Int32
    @@records[name]?.try(&.seconds) || WEIGHTS[name]? || 6
  end

  @@gate : File? = nil

  # Takes the machine's gate lock for the life of this process, or fails
  # naming the checkout that holds it.
  private def hold_gate : Nil
    gate = File.open(GATE, "a+")
    begin
      gate.flock_exclusive(blocking: false)
    rescue IO::Error
      holder = File.read(GATE).strip
      gate.close
      Checks.fail("Another check all is running from #{holder}; wait for it to finish")
    end
    gate.truncate
    gate.puts(Checks::REPO)
    gate.flush
    @@gate = gate
  end

  # Lanes for this machine: the smaller of half its cores and a quarter of
  # its memory in GB, from 2 to MAX_LANES. Without a readable memory size the
  # cores alone decide.
  private def default_lanes : {Int32, Int32, Int32?}
    cores = System.cpu_count.to_i
    memory = Checks.run(["/usr/sbin/sysctl", "-n", "hw.memsize"], timeout: 5.seconds)
    bytes = memory.success? ? memory.stdout.strip.to_i64? : nil
    gigabytes = bytes.try { |size| (size >> 30).to_i }
    lanes = gigabytes ? {cores // 2, gigabytes // 4}.min : cores // 2
    {lanes.clamp(2, MAX_LANES), cores, gigabytes}
  end

  # The durations and lanes recorded by the last runs on this machine, from
  # DURATIONS in the toolchain root; empty when the file is missing or unreadable.
  private def read_records : Hash(String, Record)
    path = File.join(File.realpath(Checks.toolchain_root), DURATIONS)
    return {} of String => Record unless File.file?(path)
    Hash(String, Record).from_json(File.read(path))
  rescue JSON::ParseException | IO::Error
    {} of String => Record
  end

  # Records the passed runs' seconds and lanes over the earlier records; a
  # failed run keeps its previous record.
  private def write_records(passed : Hash(String, Record)) : Nil
    path = File.join(File.realpath(Checks.toolchain_root), DURATIONS)
    merged = @@records.merge(passed)
    temp = "#{path}.#{Random::Secure.hex(4)}"
    File.write(temp, merged.to_pretty_json, perm: 0o600)
    File.rename(temp, path)
  rescue IO::Error
    puts "Could not record the runs' durations in #{path}"
  end

  # The lane's total and its longest run, from the runs that reported.
  private def summarize(index : Int32, names : Array(String), passed : Hash(String, Record),
                        failed : Hash(String, Int32)) : Nil
    seconds = names.map { |name| {name, passed[name]?.try(&.seconds) || failed[name]? || 0} }
    total = seconds.sum(&.[1])
    longest = seconds.max_by(&.[1])
    puts "Lane #{index + 1}: #{total} s (longest #{longest[0]} at #{longest[1]} s)"
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

  # Runs one step, prints its PASS or FAIL line and returns whether it passed
  # and how long it took. A failure's output, or the exception that stopped
  # it, goes to a log named on that line.
  private def report(name : String,
                     argv : Array(String),
                     env : Hash(String, String?)?) : {Bool, Int32}
    started = Time.instant
    result = begin
      run(argv, env)
    rescue ex
      ex
    end
    seconds = (Time.instant - started).total_seconds.round.to_i
    if result.is_a?(Caramel::Latte::ProcessResult) && result.success?
      puts "PASS #{name} (#{seconds} s)"
      return {true, seconds}
    end
    output = result.is_a?(Exception) ? result.inspect_with_backtrace : result.stdout + result.stderr
    directory = @@logs ||= Checks.private_temp("caramel-check-all-")
    log = File.join(directory, "#{name}.log")
    File.write(log, output)
    puts "FAIL #{name} (#{seconds} s): #{log}"
    {false, seconds}
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

  # Every check in scripts/checks, each run as `scripts/check NAME`.
  private def targets : Array(Run)
    paths = Dir.glob(File.join(Checks::REPO, "scripts/checks/*.cr"))
    names = paths.map { |path| File.basename(path, ".cr").tr("_", "-") }.sort!
    (names - EXEMPT).map { |name| {name, [script("check"), name]} }
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
