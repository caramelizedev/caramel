require "./support/harness"

# Lints the framework with Caramel's RFC-0008 rule set (.ameba.yml, ADR
# 0017), after proving that bin/frappe-lint carries Caramel's own rule and
# that the framework's line limit is on (ADR 0021). Under scripts/check all
# the build step has just built the linter.
module Caramel::Checks::Lint
  extend self

  LINTER = File.join(Checks::REPO, "bin/frappe-lint")
  CONFIG = File.join(Checks::REPO, ".ameba.yml")

  def main : Int32
    unless Checks.prebuilt?
      built = Checks.run([File.join(Checks::REPO, "scripts/build-lint")], timeout: 600.seconds)
      Checks.fail(built.stdout + built.stderr) unless built.success?
    end
    service_nouns
    line_length
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
    reported = issues("Caramel/ServiceNoun", <<-CRYSTAL)
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
    names = reported.map { |(line, message)| "#{line}:#{message[/`(\w+)`/, 1]?}" }
    unless names == ["1:InvitationService", "4:AbstractDataTransformerFactory"]
      Checks.fail("Caramel/ServiceNoun reported #{names.inspect}")
    end
    puts "PASS: Caramel/ServiceNoun reports InvitationService and " \
         "AbstractDataTransformerFactory, not Teams::Invite or Team"
  end

  # ADR 0021: the framework's configuration holds a line to 100 characters.
  private def line_length : Nil
    reported = issues("Layout/LineLength", "# #{"x" * 98}\n# #{"x" * 99}\n")
    lines = reported.map(&.[0])
    Checks.fail("Layout/LineLength reported lines #{lines.inspect}") unless lines == [2]
    puts "PASS: Layout/LineLength reports a 101-character line, not a 100-character one"
  end

  # The line and message of each issue `rule` reports in `source`, linted
  # alone under the framework's configuration.
  private def issues(rule : String, source : String) : Array({Int32, String})
    root = Checks.private_temp("caramel-lint-")
    begin
      File.write(File.join(root, "probe.cr"), source)
      argv = [LINTER, "--config", CONFIG, "--format", "flycheck", "probe.cr"]
      result = Checks.run(argv, chdir: root, timeout: 60.seconds)
      result.stdout.lines.compact_map do |line|
        match = line.match(/\A[^:]+:(\d+):\d+: \w: \[#{Regex.escape(rule)}\] (.*)\z/)
        match.try { |found| {found[1].to_i, found[2]} }
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

exit Caramel::Checks::Lint.main
