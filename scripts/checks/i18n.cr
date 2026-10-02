require "./support/harness"

# caramel/i18n (ADR 0024). Each catalog mistake fails to compile at its own
# line with a fixed problem text; an application that does not require
# caramel/i18n holds none of its code; and spec/i18n passes. Those specs
# replace framework methods for their whole program, so they run here, as
# their own program, instead of in the main spec run.

FIXTURES = "spec/fixtures/i18n"
ABSENT   = "i18n code must be absent from an application that does not require caramel/i18n"
# A string only caramel/i18n's request handling holds.
MARKER = "__Host-caramel_locale"

# Each fixture's problem text, by the fixture's name after `compile_`.
PROBLEMS = [
  {"code", "locale code 'French' is not a language tag such as fr, pt-BR or zh-Hant"},
  {"twice", "locale 'en' is declared twice"},
  {"key_identifier", "catalog key 'home.Title' is not a lowercase identifier"},
  {"key_reserved", "catalog key 'home.class' is reserved by Crystal or Caramel"},
  {"interpolation", "catalog text is literal: 'home.greeting' interpolates Crystal; " \
                    "write %{name} placeholders"},
  {"extra_key", "fr defines 'home.extra', which the default locale en does not"},
  {"placeholders", "'home.greeting' in fr uses placeholders name, but en uses user"},
  {"kind", "'books.count' is a plural in fr but a message in en"},
  {"plural_lacks", "plural 'books.count' in fr lacks the many form"},
  {"plural_extra", "plural 'books.count' in en has a few form, which en does not use"},
  {"no_rules", "no plural rules for 'tlh'"},
  {"framework_key", "unknown framework key 'caramel.errors.bogus'"},
  {"time_format", "time format 'caramel.time.formats.date' uses %Q, " \
                  "which Caramel does not format"},
  {"separator", "'caramel.number.separator' must be one character"},
  {"months", "'caramel.time.months' needs 12 names"},
  {"default", "Caramel.locales default: 'de' names no declared locale"},
  {"no_catalog", "Caramel.locales needs a Caramel.locale catalog before it"},
  {"placeholder_name", "catalog placeholder '%{User}' in 'home.greeting' " \
                       "is not a lowercase identifier"},
  {"framework_placeholders", "'caramel.errors.at_least' in en uses placeholders count, " \
                             "but Caramel passes min"},
  {"group_collision", "catalog keys 'shelf1' and 'shelf_1' both name the group type Shelf1"},
  {"finished", "require \"caramel/i18n\" needs Caramel.locales after the locale catalogs"},
]
# The guard runs once the program is complete, so it names no fixture line.
UNLOCATED    = %w[compile_finished]
REMEDIATIONS = {
  "compile_no_rules" => "add `plural: \"en\"` naming a language with the same plural rules",
  "compile_finished" => "Caramel.locales default: \"en\"",
}

cases = {"compile_valid" => nil} of String => String?
PROBLEMS.each { |(name, problem)| cases["compile_#{name}"] = problem }

sources = cases.keys.map { |name| "#{FIXTURES}/#{name}.cr" }
results = Caramel::Checks.type_check(sources)
cases.each_with_index do |(name, problem), index|
  result = results[index]
  output = "#{name}\n#{result.stdout}#{result.stderr}"
  Caramel::Checks.fail("#{name}\ncompiler timed out") if result.timed_out?
  if problem
    Caramel::Checks.fail(output) if result.success?
    required = [problem]
    required << "#{name}.cr:" unless UNLOCATED.includes?(name)
    REMEDIATIONS[name]?.try { |remediation| required << remediation }
    missing = required.find { |text| !result.stderr.includes?(text) }
    Caramel::Checks.fail("missing #{missing.inspect} in #{output}") if missing
  else
    Caramel::Checks.fail(output) unless result.success?
  end
  puts "PASS: #{name}"
end

# The same application without and with caramel/i18n: only the second holds
# its code, and each answers as it should.
root = Caramel::Checks.private_temp("caramel-i18n-")
at_exit { FileUtils.rm_rf(root) }
answers = {"plain" => "200 -\n404 -\n", "localized" => "200 fr\n404 fr\n"}
answers.each do |name, expected|
  binary = File.join(root, name)
  build = Caramel::Checks.crystal(["build", "#{FIXTURES}/#{name}.cr", "-o", binary],
    timeout: 1.hour)
  Caramel::Checks.fail(build.stdout + build.stderr) unless build.success?
  present = File.read(binary).includes?(MARKER)
  Caramel::Checks.fail(ABSENT) unless present == (name == "localized")
  answered = Caramel::Checks.run([binary], timeout: 1.minute)
  unless answered.success? && answered.stdout == expected
    Caramel::Checks.fail("#{name} answered:\n#{answered.stdout}#{answered.stderr}")
  end
end
puts "PASS: an application without caramel/i18n holds none of its code, " \
     "and one with it negotiates fr"

specs = Caramel::Checks.crystal(["spec", "spec/i18n"], timeout: 1.hour)
STDOUT.print specs.stdout
STDERR.print specs.stderr
Caramel::Checks.fail("spec/i18n failed") unless specs.success?
puts "PASS: spec/i18n"
