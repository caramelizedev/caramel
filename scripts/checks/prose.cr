require "yaml"
require "./support/harness"

# The repository keeps to its layout (ADR 0014). Every kind of writing has one home:
# markdown lives only in the files that state a contract, each decision record keeps its
# three sections, every relative link resolves, and every capped file stays within its
# byte cap. And the sweettalk shard is apart from the framework: no file of the
# framework names it, and the two state one version (ADR 0030).
module Caramel::Checks::Prose
  extend self

  # A framework record, or a SweetTalk record in its own directory.
  ADR_PATH = /\Adocs\/decisions\/(sweettalk\/)?\d{4}-[a-z0-9-]+\.md\z/

  HOMES = [
    /\A(README|CONTRIBUTING|CHANGELOG|AGENTS|CLAUDE|SECURITY|THIRD_PARTY_NOTICES)\.md\z/,
    ADR_PATH,
    /\Awebsite\/README\.md\z/,
    /\Atemplates\/application\/(README|AGENTS|CLAUDE)\.md\z/,
    /\Asweettalk\/(README|templates\/SKILL)\.md\z/,
    /\A\.claude\/skills\/(caramel-docs|caramel-triage)\/SKILL\.md\z/,
    /\A(website\/)?vendor\//,
  ]

  CAPS = {
    "README.md"                       => 3_000,
    "AGENTS.md"                       => 3_000,
    "CLAUDE.md"                       => 200,
    "CONTRIBUTING.md"                 => 12_000,
    "SECURITY.md"                     => 2_000,
    "website/README.md"               => 6_000,
    "templates/application/README.md" => 3_000,
    "templates/application/AGENTS.md" => 2_000,
    "templates/application/CLAUDE.md" => 200,
    "sweettalk/README.md"             => 1_000,
    # A decision record has no cap: it is as long as its subject. A skill has none
    # either: it is read when its task matches, and the link check keeps it from
    # becoming a second source (ADR 0014).
  }

  ADR_TITLE  = /\A# ADR (\d{4}): \S/
  ADR_DATE   = /\ADate: \d{4}-\d{2}-\d{2}\z/
  ADR_STATUS = "Status: "
  ADR_SHAPES = [%w[Decision Reasons], %w[Context Decision Reasons]]

  LINK   = /\]\(([^)\s]+)\)/
  SCHEME = /\A[a-z][a-z0-9+.-]*:/i
  VENDOR = /\A(website\/)?vendor\//

  # The framework's sources and templates, which an application builds from: the products
  # under src/ and what Frappé generates from. None of it names the sweettalk shard, in
  # any spelling: the framework neither holds the shard nor knows it.
  FRAMEWORK = %w[src templates]
  SWEETTALK = /sweet[ _-]?talk/i
  # The framework's shard.yml and the shard's, which state one version.
  MANIFEST       = "shard.yml"
  SHARD_MANIFEST = "sweettalk/shard.yml"

  def main : Int32
    listed = listed_paths
    paths = markdown_paths(listed)
    problems = [] of String
    paths.each { |path| problems.concat(homeless(path)) }
    homed = paths.select { |path| HOMES.any?(&.matches?(path)) }
    adrs = homed.select(&.matches?(ADR_PATH))
    adrs.each { |path| problems.concat(adr_problems(path)) }
    homed.each { |path| problems.concat(link_problems(path)) }
    homed.each { |path| problems.concat(cap_problems(path)) }
    framework = listed.select { |path| FRAMEWORK.any? { |tree| path.starts_with?("#{tree}/") } }
    framework.each { |path| problems.concat(boundary_problems(path)) }
    problems.concat(version_problems)
    Checks.fail(problems.join("\n")) unless problems.empty?
    puts "PASS: #{homed.size} markdown files sit in their homes, #{adrs.size} ADRs keep " \
         "Context, Decision and Reasons, every relative link resolves, and every capped " \
         "file is within its cap"
    puts "PASS: none of the framework's #{framework.size} files names SweetTalk, and " \
         "#{SHARD_MANIFEST} states the version of #{MANIFEST} and depends on it"
    0
  end

  # The tracked and unignored files of the repository.
  private def listed_paths : Array(String)
    listing = %w[ls-files -z --cached --others --exclude-standard]
    listed = Checks.run(["/usr/bin/git", "-C", Checks::REPO] + listing).stdout
    listed.split('\0', remove_empty: true).select { |path| File.file?(absolute(path)) }
  end

  # Those of *paths* that are markdown or live under docs/.
  private def markdown_paths(paths : Array(String)) : Array(String)
    paths.select { |path| path.ends_with?(".md") || path.starts_with?("docs/") }
  end

  # Where *path*, a file of the framework, names the sweettalk shard: in its own name,
  # or on a line.
  private def boundary_problems(path : String) : Array(String)
    rule = "the framework names SweetTalk nowhere (ADR 0014); say it in the sweettalk " \
           "shard, or in words that fit any library"
    problems = [] of String
    problems << "#{path}: its path names SweetTalk; #{rule}" if path.matches?(SWEETTALK)
    File.read(absolute(path)).scrub.each_line.with_index(1) do |line, number|
      problems << "#{path}:#{number}: names SweetTalk; #{rule}" if line.matches?(SWEETTALK)
    end
    problems
  end

  # Where the shard's shard.yml and the framework's disagree on the version.
  private def version_problems : Array(String)
    version = YAML.parse(File.read(absolute(MANIFEST)))["version"].as_s
    shard = YAML.parse(File.read(absolute(SHARD_MANIFEST)))
    own = shard["version"]?.try(&.as_s?)
    needed = shard.dig?("dependencies", "caramel", "version").try(&.as_s?)
    problems = [] of String
    unless own == version
      problems << "#{SHARD_MANIFEST}: version is #{own.inspect}, and #{MANIFEST} states " \
                  "#{version}; the shard shares the framework's version (ADR 0030)"
    end
    unless needed == version
      problems << "#{SHARD_MANIFEST}: depends on caramel #{needed.inspect}, and #{MANIFEST} " \
                  "states #{version}; the shard depends on exactly that version (ADR 0030)"
    end
    problems
  end

  private def absolute(path : String) : String
    File.join(Checks::REPO, path)
  end

  private def homeless(path : String) : Array(String)
    return [] of String if HOMES.any?(&.matches?(path))
    ["#{path}: not a home for writing; contracts go in CONTRIBUTING.md, an ADR or the " \
     "website, and history, status and research go to caramelizedev/caramel-notes"]
  end

  private def adr_problems(path : String) : Array(String)
    lines = File.read_lines(absolute(path))
    problems = [] of String
    number = path.match(/\/(\d{4})-/).try(&.[1])
    title = lines.first?.try(&.match(ADR_TITLE))
    unless title && title[1] == number
      problems << "#{path}: line 1 must be `# ADR #{number}: <title>`"
    end
    found = headings(lines)
    unless ADR_SHAPES.includes?(found)
      problems << "#{path}: sections are #{found.inspect}; an ADR has Decision and " \
                  "Reasons, with an optional Context first"
    end
    problems.concat(adr_header_problems(path, lines))
  end

  private def adr_header_problems(path : String, lines : Array(String)) : Array(String)
    first = lines.index(&.starts_with?("## ")) || lines.size
    header = lines[0...first]
    dated = header.any?(&.matches?(ADR_DATE))
    stated = header.any?(&.starts_with?(ADR_STATUS))
    problems = [] of String
    problems << "#{path}: no `Date: YYYY-MM-DD` line before the first section" unless dated
    problems << "#{path}: no `Status: ` line before the first section" unless stated
    problems
  end

  private def headings(lines : Array(String)) : Array(String)
    prose(lines).select(&.starts_with?("## ")).map(&.lchop("## "))
  end

  # The lines outside fenced code blocks.
  private def prose(lines : Array(String)) : Array(String)
    fenced = false
    lines.reject do |line|
      fence = line.lstrip.starts_with?("```")
      fenced = !fenced if fence
      fence || fenced
    end
  end

  private def link_problems(path : String) : Array(String)
    return [] of String if path == "CHANGELOG.md" || path.matches?(VENDOR)
    directory = File.dirname(absolute(path))
    lines = prose(File.read_lines(absolute(path)))
    targets = lines.flat_map { |line| line.scan(LINK).map(&.[1]) }
    targets.compact_map do |target|
      next if target.matches?(SCHEME) || target.starts_with?("#")
      local = target.split(/[#?]/).first
      next if File.exists?(File.expand_path(local, directory))
      "#{path}: link to #{target} resolves to nothing"
    end
  end

  private def cap_problems(path : String) : Array(String)
    cap = CAPS[path]?
    return [] of String unless cap
    size = File.size(absolute(path))
    return [] of String if size <= cap
    ["#{path}: #{size} bytes; its cap is #{cap} (CONTRIBUTING.md, Writing)"]
  end
end

exit Caramel::Checks::Prose.main
