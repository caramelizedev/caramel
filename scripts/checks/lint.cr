require "yaml"
require "./support/harness"

# Lints the framework with Caramel's RFC-0008 rule set (.ameba.yml, ADR
# 0017), after proving that bin/frappe-lint carries Caramel's own rule and
# that the framework's line limit is on (ADR 0021). Under scripts/check all
# the build step has just built the linter.
module Caramel::Checks::Lint
  extend self

  LINTER = File.join(Checks::REPO, "bin/frappe-lint")
  CONFIG = File.join(Checks::REPO, ".ameba.yml")
  LIMIT  = 100

  def main : Int32
    unless Checks.prebuilt?
      built = Checks.run([File.join(Checks::REPO, "scripts/build-lint")], timeout: 600.seconds)
      Checks.fail(built.stdout + built.stderr) unless built.success?
    end
    service_nouns
    line_length
    exemptions
    framework = Checks.run([LINTER, "--format", "flycheck"], timeout: 300.seconds)
    unless framework.success?
      Checks.fail("The framework does not pass its rule set:\n" \
                  "#{framework.stdout}#{framework.stderr}")
    end
    puts "PASS: the framework passes Caramel's RFC-0008 rule set " \
         "(Ameba 1.7.0 and Caramel/ServiceNoun)"
    0
  end

  # RFC-0008 §2.1: service nouns are reported; subjects, verbs and actions
  # are not.
  private def service_nouns : Nil
    result = probe(<<-CRYSTAL)
      class InvitationService
      end

      module AbstractDataTransformerFactory
      end

      struct Teams::Invite
      end

      class Team
        def invite(email : String) : Nil
        end
      end

      CRYSTAL
    names = issues(result, "Caramel/ServiceNoun").map do |(line, message)|
      "#{line}:#{message[/`(\w+)`/, 1]?}"
    end
    expected = ["1:InvitationService", "4:AbstractDataTransformerFactory"]
    refuse("Caramel/ServiceNoun", names, result) if result.success? || names != expected
    puts "PASS: Caramel/ServiceNoun reports InvitationService and " \
         "AbstractDataTransformerFactory, not Teams::Invite or Team"
  end

  # ADR 0021: the framework's configuration holds a line to 100 characters.
  private def line_length : Nil
    result = probe("# #{"x" * (LIMIT - 2)}\n# #{"x" * (LIMIT - 1)}\n")
    lines = issues(result, "Layout/LineLength").map(&.[0])
    refuse("Layout/LineLength", lines, result) if result.success? || lines != [2]
    puts "PASS: Layout/LineLength reports a 101-character line, not a 100-character one"
  end

  # ADR 0021: a file the rule excludes leaves the list once its long lines
  # are rewritten.
  private def exemptions : Nil
    rule = YAML.parse(File.read(CONFIG))["Layout/LineLength"]?
    listed = rule.try(&.["Excluded"]?).try(&.as_a.map(&.as_s)) || [] of String
    stale = listed.reject { |path| long_line?(File.join(Checks::REPO, path)) }
    unless stale.empty?
      Checks.fail("Layout/LineLength excludes files without a long line; " \
                  "remove them from .ameba.yml:\n#{stale.join('\n')}")
    end
    puts "PASS: each of the #{listed.size} files Layout/LineLength excludes " \
         "still has a line to rewrite"
  end

  private def long_line?(path : String) : Bool
    File.exists?(path) && File.read_lines(path).any? { |line| line.size > LIMIT }
  end

  # The linter's run over `source`, alone, under the framework's configuration.
  private def probe(source : String)
    root = Checks.private_temp("caramel-lint-")
    begin
      File.write(File.join(root, "probe.cr"), source)
      argv = [LINTER, "--config", CONFIG, "--format", "flycheck", "probe.cr"]
      Checks.run(argv, chdir: root, timeout: 60.seconds)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  # The line and message of each issue `rule` reported in a probe's run.
  private def issues(result, rule : String) : Array({Int32, String})
    result.stdout.lines.compact_map do |line|
      match = line.match(/\A[^:]+:(\d+):\d+: \w: \[#{Regex.escape(rule)}\] (.*)\z/)
      match.try { |found| {found[1].to_i, found[2]} }
    end
  end

  # Fails with the linter's own output, so a crash or a configuration error
  # shows itself.
  private def refuse(rule : String, reported, result) : NoReturn
    Checks.fail("#{rule} reported #{reported.inspect}:\n#{result.stdout}#{result.stderr}")
  end
end

exit Caramel::Checks::Lint.main
