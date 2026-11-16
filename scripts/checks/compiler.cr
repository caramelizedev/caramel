require "json"
require "./support/harness"

{"puts 1", %(require "http"; puts 1)}.each do |source|
  result = Caramel::Checks.crystal(["eval", source], timeout: 1.hour)
  unless result.success? && result.stdout.strip == "1"
    STDERR.print result.stdout, result.stderr
    Caramel::Checks.fail("Managed Crystal eval regression")
  end
end
puts "Managed Crystal eval and OpenSSL loading: passed"

# The managed compiler is Caramel's build of the pinned release (ADR 0001).
build = File.join(Caramel::Checks.toolchain_root,
  "data/installs/github-caramelizedev-caramel-crystal/1.22.3-caramel.1")

# It carries the multi-threaded runtime, so it generates code on several
# threads. The official macOS binary has none and ignores --threads.
count = %(/usr/bin/nm "$1" | /usr/bin/grep -c 'Fiber::ExecutionContext')
threaded = Caramel::Checks.run(["/bin/sh", "-c", count, "sh", File.join(build, "crystal")])
Caramel::Checks.fail("Managed Crystal generates code on one thread") unless threaded.success?
puts "Managed Crystal generates code on several threads: passed"

# A program it builds links the PCRE2 that build ships, not the older one in
# the official archive.
shipped = JSON.parse(File.read(File.join(build, "BUILD.json")))["pcre2"]["version"].as_s
linked = Caramel::Checks.crystal(["eval", "puts Regex::PCRE2.version"], timeout: 1.hour)
unless linked.success? && linked.stdout.starts_with?("#{shipped} ")
  STDERR.print linked.stdout, linked.stderr
  Caramel::Checks.fail("A managed build links another PCRE2 than the shipped #{shipped}")
end
puts "Managed builds link the shipped PCRE2 #{shipped}: passed"
