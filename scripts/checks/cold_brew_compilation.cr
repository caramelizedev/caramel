require "./support/harness"

# Cold Brew's usage examples must compile as written.
fixture = "spec/fixtures/cold_brew/usage_examples.cr"
result = Caramel::Checks.crystal(["build", fixture, "--no-codegen"], timeout: 90.seconds)
Caramel::Checks.fail("#{fixture}\ncompiler timed out") if result.timed_out?
Caramel::Checks.fail("#{fixture}\n#{result.stdout}#{result.stderr}") unless result.success?
puts "PASS: the SendInvitation job and transactional enqueue, " \
     "every schedule and the Boards::Live action compile as written"
