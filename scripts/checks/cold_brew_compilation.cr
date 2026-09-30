require "./support/harness"

# The RFC-0003 code blocks must compile exactly as the RFC prints them.
fixture = "spec/fixtures/cold_brew/rfc_snippets.cr"
result = Caramel::Checks.crystal(["build", fixture, "--no-codegen"], timeout: 90.seconds)
Caramel::Checks.fail("#{fixture}\ncompiler timed out") if result.timed_out?
Caramel::Checks.fail("#{fixture}\n#{result.stdout}#{result.stderr}") unless result.success?
puts "PASS: RFC-0003 §2.1 SendInvitation job and transactional enqueue, " \
     "§2.2 every schedule and §2.3 Boards::Live action compile as written"
