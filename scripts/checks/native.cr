require "./support/harness"

builders = %w[scripts/build-latte-menu scripts/build-latte-relay scripts/build-installers]
# Under scripts/check all the build step has already built Latte.app and the
# port relay.
builders -= %w[scripts/build-latte-menu scripts/build-latte-relay] if Caramel::Checks.prebuilt?
builders.each do |builder|
  result = Caramel::Checks.run([File.join(Caramel::Checks::REPO, builder)], timeout: 300.seconds)
  STDOUT.print result.stdout
  STDERR.print result.stderr
  exit result.status.exit_code unless result.success?
end
installers = File.join(Caramel::Checks::REPO, "scripts/build-installers")
result = Caramel::Checks.run([installers, "--test"], timeout: 300.seconds)
STDOUT.print result.stdout
STDERR.print result.stderr
exit result.status.exit_code unless result.success?

result = Caramel::Checks.crystal(["spec", "spec/native", "--error-trace"], timeout: 300.seconds)
STDOUT.print result.stdout
STDERR.print result.stderr
exit result.status.exit_code unless result.success?
