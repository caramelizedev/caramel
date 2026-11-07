require "./support/harness"
require "../../src/frappe/word_drift"

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

# The SweetTalk guide's Markdown edition and the skill name no option that a word lacks, the
# guide names every word and option, and each word's @guide is a section of the guide.
repo = Caramel::Checks::REPO
words = Caramel::Frappe::Words.load(repo)
drift = Caramel::Frappe::WordDrift.new(words)
guide = File.read(File.join(repo, "website/dist/docs/#{version}/sweettalk/index.md"))
skill = File.read(File.join(repo, "templates/skills/sweettalk/SKILL.md"))
problems = drift.prose(guide, "the SweetTalk guide", guide: true) +
           drift.prose(skill, "templates/skills/sweettalk/SKILL.md") +
           drift.sections(guide, "the SweetTalk guide")
unless problems.empty?
  Caramel::Checks.fail("SweetTalk's words and its prose differ:\n#{problems.join("\n")}")
end
puts "PASS: the SweetTalk guide and skill name no option that #{words.words.size} words lack"
