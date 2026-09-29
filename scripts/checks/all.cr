require "./support/harness"

# Builds Frappé, Latte and the linter, runs the spec suite, then every
# pass/fail check one after another (they share one compiler cache), and
# reports each result. Once the build step passes, the checks reuse its
# binaries (Checks::PREBUILT). A failed run's full output is kept in a log
# named on its FAIL line. A release requires every run to pass.
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

    runs = [
      {"build", [script("build-frappe"), "&&", script("build-latte"), "&&", script("build-lint")]},
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

  # A `&&` chain runs its commands in order and stops at the first failure.
  private def run(argv : Array(String)) : Caramel::Latte::ProcessResult
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
