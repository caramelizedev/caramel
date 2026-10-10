require "./support/harness"

# Cold Brew's usage examples must compile as written, and a job name that two
# jobs claim must not compile.
fixture = "spec/fixtures/cold_brew/usage_examples.cr"
result = Caramel::Checks.crystal(["build", fixture, "--no-codegen"], timeout: 90.seconds)
Caramel::Checks.fail("#{fixture}\ncompiler timed out") if result.timed_out?
Caramel::Checks.fail("#{fixture}\n#{result.stdout}#{result.stderr}") unless result.success?
puts "PASS: the SendInvitation job and transactional enqueue, its renamed_from alias, " \
     "every schedule and the Boards::Live action compile as written"

cases = {
  "compile_renamed_from_shared" => [
    "App::Restock and App::RestockTea both claim \"App::Stock\" in renamed_from",
    "Remediation: only one job can take over a name",
  ],
  "compile_renamed_from_job_name" => [
    "App::RestockTea claims \"App::Restock\" in renamed_from, but App::Restock is a job",
    "renamed_from \"App::Restock\"",
  ],
  "compile_renamed_from_own_name" => [
    "App::RestockTea lists its own name in renamed_from",
    "renamed_from \"App::RestockTea\"",
  ],
  "compile_renamed_from_invalid" => [
    "renamed_from expects the old class names as string literals",
    "compile_renamed_from_invalid.cr:5:18",
  ],
  "compile_renamed_from_abstract" => [
    "renamed_from is declared on abstract App::Mail, which no row can name",
    "Remediation: declare it on the concrete job that replaced the old class",
  ],
  "compile_renamed_from_twice" => [
    "App::RestockTea declares renamed_from twice",
    "Remediation: list every old name in one `renamed_from` line",
  ],
}
sources = cases.keys.map { |name| "spec/fixtures/cold_brew/#{name}.cr" }
results = Caramel::Checks.type_check(sources)
cases.each_with_index do |(name, required), index|
  result = results[index]
  output = "#{name}\n#{result.stdout}#{result.stderr}"
  Caramel::Checks.fail(output) if result.success?
  Caramel::Checks.fail("#{name}\ncompiler timed out") if result.timed_out?
  required.each do |text|
    next if result.stderr.includes?(text)
    Caramel::Checks.fail("missing #{text.inspect} in #{output}")
  end
  puts "PASS: #{name}"
end
