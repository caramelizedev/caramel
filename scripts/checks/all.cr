require "./support/harness"

# Builds Frappé, Latte, the linter and the LatteFixture environment daemon,
# runs the spec suite, then every pass/fail check one after another (they
# share one compiler cache; only compiles inside one step run side by side,
# as CONTRIBUTING.md describes), and reports each result. Once the build step
# passes, the checks reuse its binaries (Checks::PREBUILT). A failed run's
# full output is kept in a log named on its FAIL line. A release requires
# every run to pass.
#
#   scripts/check all [--except NAME ...]
#
# --except skips a check, such as latte-daemon while your own Latte holds
# its fixed ports; a release never skips any.
module Caramel::Checks::All
  extend self

  # Performance measurements, not pass/fail checks.
  EXEMPT = %w[all compiler-profile]
  SPECS  = %w[spec/caramel spec/frappe spec/latte spec/sugar_orm spec/cold_brew spec/corretto spec/release]

  def main(args : Array(String)) : Int32
    skipped = [] of String
    rest = args.dup
    while flag = rest.shift?
      Checks.fail("usage: scripts/check all [--except NAME ...]") unless flag == "--except" && (skip = rest.shift?)
      skipped << skip
    end
    unknown = skipped - targets.map(&.first)
    Checks.fail("unknown check: #{unknown.join(", ")}") unless unknown.empty?
    prune_program_caches

    runs = [
      # The linter, the longest build, compiles alongside the rest: two Crystal
      # builds at a time (CONTRIBUTING.md).
      {"build", [script("build-lint"), "&",
                 script("build-frappe"), "&&", script("build-latte"), "&&",
                 script("crystal"), "build", File.join(Checks::REPO, "spec/fixtures/frappe_environment.cr"), "-o", Checks::PREBUILT_ENVIRONMENT]},
      {"spec", [script("crystal"), "spec"] + SPECS},
    ] + targets.reject { |name, _| skipped.includes?(name) }
    failed = [] of String
    logs = nil
    runs.each do |name, argv|
      started = Time.instant
      result = run(argv)
      seconds = (Time.instant - started).total_seconds.round.to_i
      if result.success?
        puts "PASS #{name} (#{seconds} s)"
        ENV[Checks::PREBUILT] = "1" if name == "build"
      else
        failed << name
        directory = logs ||= Checks.private_temp("caramel-check-all-")
        log = File.join(directory, "#{name}.log")
        File.write(log, result.stdout + result.stderr)
        puts "FAIL #{name} (#{seconds} s): #{log}"
      end
    end
    puts skipped.empty? ? "Ran every check." : "Skipped: #{skipped.join(", ")}"
    if failed.empty?
      puts "All #{runs.size} runs passed."
      0
    else
      puts "Failed: #{failed.join(", ")}"
      1
    end
  end

  # scripts/crystal gives each checkout program a compiler cache root of its
  # own. A root no build has touched for 30 days, such as a renamed check's,
  # is deleted before the build step.
  private def prune_program_caches : Nil
    root = ENV["CARAMEL_TOOLCHAIN_ROOT"]? || return
    programs = File.join(File.realpath(root), "crystal-cache-programs")
    return unless Dir.exists?(programs)
    cutoff = Time.utc - 30.days
    Dir.each_child(programs) do |name|
      path = File.join(programs, name)
      info = File.info?(path, follow_symlinks: false) || next
      FileUtils.rm_rf(path) if info.directory? && info.modification_time < cutoff
    end
  end

  # Every check in scripts/checks. frappe-project runs once, with --dev: that
  # run executes every step of the plain flow as well as its dev phase.
  private def targets : Array({String, Array(String)})
    names = Dir.glob(File.join(Checks::REPO, "scripts/checks/*.cr")).map { |path| File.basename(path, ".cr").tr("_", "-") }.sort!
    checks = (names - EXEMPT - ["frappe-project"]).map { |name| {name, [script("check"), name]} }
    checks << {"frappe-project-dev", [script("check"), "frappe-project", "--dev"]}
    checks
  end

  private def script(name : String) : String
    File.join(Checks::REPO, "scripts", name)
  end

  # A run is `&&` chains joined by `&`. The chains run side by side; the run
  # passes when every chain does, and its output is theirs, in order.
  private def run(argv : Array(String)) : Caramel::Latte::ProcessResult
    chains = argv.chunk_while { |_, word| word != "&" }.map(&.reject("&")).reject(&.empty?).to_a
    finished = Channel({Int32, Caramel::Latte::ProcessResult | Exception}).new(chains.size)
    chains.each_with_index do |chain, index|
      spawn do
        finished.send({index, run_chain(chain)})
      rescue ex
        finished.send({index, ex})
      end
    end
    results = Array.new(chains.size) { finished.receive }.sort_by!(&.[0]).map do |(_, outcome)|
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
    failed = results.find { |result| !result.success? }
    Caramel::Latte::ProcessResult.new((failed || results.last).status, results.map(&.stdout).join, results.map(&.stderr).join, results.any?(&.timed_out?))
  end

  # A `&&` chain runs its commands in order and stops at the first failure.
  private def run_chain(argv : Array(String)) : Caramel::Latte::ProcessResult
    commands = argv.chunk_while { |_, word| word != "&&" }.map(&.reject("&&")).reject(&.empty?)
    result = nil
    commands.each do |command|
      result = Checks.run(command, timeout: 1800.seconds)
      return result unless result.success?
    end
    result || raise "empty run"
  end
end

exit Caramel::Checks::All.main(ARGV)
