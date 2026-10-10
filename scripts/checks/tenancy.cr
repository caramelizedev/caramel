require "./support/harness"

# caramel/tenancy (ADR 0025). Each declaration mistake fails to compile with a
# fixed problem text that names its file; and an application that does not
# require caramel/tenancy holds none of its code. spec/tenancy needs
# PostgreSQL, so scripts/check integration runs it.

FIXTURES = "spec/fixtures/tenancy"
ABSENT   = "tenancy code must be absent from an application that does not require " \
           "caramel/tenancy"
# A string only caramel/tenancy's scoping holds.
MARKER = "is tenanted, but no tenant is bound"

# Each fixture's problem text, by the fixture's name after `compile_`.
PROBLEMS = [
  {"tenant_without_require", "tenant needs require \"caramel/tenancy\""},
  {"tenant_block_without_require", "tenant ... do needs require \"caramel/tenancy\""},
  {"missing_tenant_block",
   "require \"caramel/tenancy\" needs a tenant block in Caramel::Router.draw"},
  {"two_tenant_blocks", "Caramel::Router.draw takes one tenant block"},
  {"tenant_twice", "tenant is declared twice"},
  {"tenant_mismatch", "names Fixture::Team, but the routes declare Fixture::Account " \
                      "as the tenant."},
  {"tenant_of_tenant", "names a tenanted schema; the tenant cannot have a tenant itself"},
  {"by_not_string", "tenant Fixture::Account, by: :seats must name a String field of " \
                    "Fixture::Account. Fields: slug"},
  {"central_parameter_route", "Route '/:name' starts with a parameter, " \
                              "which would take every tenant's address"},
  {"duplicate_table", "Fixture::Volume declares the table \"books\", " \
                      "which Fixture::Book already declares."},
  {"shared_first_segment", "Route '/books/shelves' in the tenant block starts with " \
                           "'books', as a central route does"},
]
# The guard runs once the program is complete, so it names no fixture line.
UNLOCATED    = %w[compile_missing_tenant_block]
REMEDIATIONS = {
  "compile_tenant_without_require"       => "add it after require \"caramel\"",
  "compile_tenant_block_without_require" => "add it after require \"caramel\"",
  "compile_tenant_mismatch"              => "Remediation: name Fixture::Account here.",
  "compile_central_parameter_route"      => "Remediation: give it a static first segment",
  "compile_shared_first_segment"         => "Remediation: rename one of them.",
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

# The same application without and with caramel/tenancy: only the second
# holds its code, and both answer a central page and an unknown one alike.
root = Caramel::Checks.private_temp("caramel-tenancy-")
at_exit { FileUtils.rm_rf(root) }
{"plain", "tenanted"}.each do |name|
  binary = File.join(root, name)
  build = Caramel::Checks.crystal(["build", "#{FIXTURES}/#{name}.cr", "-o", binary],
    timeout: 1.hour)
  Caramel::Checks.fail(build.stdout + build.stderr) unless build.success?
  present = File.read(binary).includes?(MARKER)
  Caramel::Checks.fail(ABSENT) unless present == (name == "tenanted")
  answered = Caramel::Checks.run([binary], timeout: 1.minute)
  unless answered.success? && answered.stdout == "200\n404\n"
    Caramel::Checks.fail("#{name} answered:\n#{answered.stdout}#{answered.stderr}")
  end
end
puts "PASS: an application without caramel/tenancy holds none of its code, " \
     "and both answer central requests alike"
