require "./support/harness"

# Lints the framework with Caramel's RFC-0008 rule set (.ameba.yml, ADR
# 0017), after proving that bin/frappe-lint carries Caramel's own rule. Under
# scripts/check all the build step has just built the linter.
module Caramel::Checks::Lint
  extend self

  LINTER = File.join(Checks::REPO, "bin/frappe-lint")

  def main : Int32
    unless Checks.prebuilt?
      built = Checks.run([File.join(Checks::REPO, "scripts/build-lint")], timeout: 600.seconds)
      Checks.fail(built.stdout + built.stderr) unless built.success?
    end
    service_nouns
    framework = Checks.run([LINTER, "--format", "flycheck"], timeout: 300.seconds)
    Checks.fail("The framework does not pass its rule set:\n#{framework.stdout}#{framework.stderr}") unless framework.success?
    puts "PASS: the framework passes Caramel's RFC-0008 rule set (Ameba 1.7.0 and Caramel/ServiceNoun)"
    0
  end

  # RFC-0008 §2.1: service nouns are reported; subjects, verbs and actions
  # are not.
  private def service_nouns : Nil
    root = Checks.private_temp("caramel-lint-")
    begin
      File.write(File.join(root, "nouns.cr"), <<-CRYSTAL)
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
      result = Checks.run([LINTER, "--only", "Caramel/ServiceNoun", "--format", "flycheck", "nouns.cr"], chdir: root, timeout: 60.seconds)
      reported = result.stdout.lines.compact_map { |line| line.match(/\A[^:]+:(\d+):\d+: .*\[Caramel\/ServiceNoun\] `(\w+)`/).try { |match| "#{match[1]}:#{match[2]}" } }
      if result.success? || reported != ["1:InvitationService", "4:AbstractDataTransformerFactory"]
        Checks.fail("Caramel/ServiceNoun reported #{reported.inspect}:\n#{result.stdout}#{result.stderr}")
      end
      puts "PASS: Caramel/ServiceNoun reports InvitationService and AbstractDataTransformerFactory, not Teams::Invite or Team"
    ensure
      FileUtils.rm_rf(root)
    end
  end
end

exit Caramel::Checks::Lint.main
