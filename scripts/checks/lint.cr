require "yaml"
require "./support/harness"

# Lints the framework with Caramel's rule set (.ameba.yml, ADR
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
    no_exemptions
    html_expectations
    framework = Checks.run([LINTER, "--format", "flycheck"], timeout: 300.seconds)
    unless framework.success?
      Checks.fail("The framework does not pass its rule set:\n" \
                  "#{framework.stdout}#{framework.stderr}")
    end
    puts "PASS: the framework passes Caramel's rule set " \
         "(Ameba 1.7.0 and Caramel/ServiceNoun)"
    0
  end

  # Service nouns are reported; subjects, verbs and actions
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

  private def html_expectations : Nil
    result = probe(<<-CRYSTAL)
      p "debug"
      response.should have_html {
        section {
          p { "Paragraph" }
          pp "debug"
          p "debug inside expectation"
        }
      }
      response.should render_partial("#notes") {
        p { "Note" }
      }
      [1].each {
        p "still debug"
      }
      CRYSTAL
    debug = issues(result, "Lint/DebugCalls").map(&.[0])
    curly = issues(result, "Style/MultilineCurlyBlock").map(&.[0])
    refuse("Lint/DebugCalls", debug, result) unless debug == [1, 5, 6, 13]
    refuse("Style/MultilineCurlyBlock", curly, result) unless curly == [12]
    puts "PASS: HTML expectation syntax is scoped; ordinary debug calls and curly blocks are linted"
  end

  # ADR 0021: no file is exempt from the line limit, by the configuration or
  # by an inline directive.
  private def no_exemptions : Nil
    rule = YAML.parse(File.read(CONFIG))["Layout/LineLength"]?
    if rule.try(&.["Excluded"]?)
      Checks.fail("Layout/LineLength excludes files in .ameba.yml; " \
                  "rewrite their long lines instead (ADR 0021)")
    end
    disabled = linted_sources.select do |path|
      File.read_lines(path).any? { |line| disables_line_length?(line) }
    end
    unless disabled.empty?
      Checks.fail("These files disable Layout/LineLength inline; " \
                  "rewrite their long lines instead (ADR 0021):\n#{disabled.join('\n')}")
    end
    puts "PASS: Layout/LineLength exempts no file, by configuration or inline directive"
  end

  # The Crystal files .ameba.yml lints: fixture data is excluded there too.
  private def linted_sources : Array(String)
    Dir.glob(File.join(Checks::REPO, "{src,spec,scripts}/**/*.cr")).reject do |path|
      path.lchop("#{Checks::REPO}/").matches?(%r{\Aspec/fixtures/[^/]+/})
    end
  end

  private def disables_line_length?(line : String) : Bool
    rules = line[/#\s*ameba:disable\s+([\w\/, ]+)/, 1]? || return false
    rules.split(/[\s,]+/).any?(&.in?("Layout", "Layout/LineLength"))
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
