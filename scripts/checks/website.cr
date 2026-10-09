require "./support/harness"

# The website builds and passes its own checks (ADR 0026). website/build.mjs
# refuses a site that does not name the version in shard.yml, so during
# scripts/release, which writes the new version first, this check builds the
# edition for the new version.
node = Process.find_executable("node") ||
       Caramel::Checks.fail("the website check needs Node.js 22 or newer on PATH")
reported = Caramel::Checks.run([node, "--version"]).stdout.strip
major = reported.lchop('v').split('.').first.to_i?
unless major && major >= 22
  Caramel::Checks.fail("the website check needs Node.js 22 or newer on PATH")
end

[
  [node, "website/build.mjs"],
  [node, "--check", "website/dist/assets/site.js"],
  [node, "website/check.mjs"],
].each do |command|
  result = Caramel::Checks.run(command, chdir: Caramel::Checks::REPO, timeout: 180.seconds)
  next if result.success?
  Caramel::Checks.fail("#{command.join(' ')} failed:\n#{result.stdout}#{result.stderr}")
end

version = File.read_lines(File.join(Caramel::Checks::REPO, "shard.yml"))
  .find!(&.starts_with?("version:")).split(':', 2)[1].strip
puts "PASS: the website builds Caramel #{version}'s edition and passes website/check.mjs"
