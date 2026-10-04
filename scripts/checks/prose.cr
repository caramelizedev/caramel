require "./support/harness"

# Every kind of writing has one home (ADR 0026): markdown lives only in the files
# that state a contract, each ADR keeps its three sections, every relative link
# resolves, and every file stays within its byte cap.
module Caramel::Checks::Prose
  extend self

  HOMES = [
    /\A(README|CONTRIBUTING|CHANGELOG|AGENTS|CLAUDE|THIRD_PARTY_NOTICES)\.md\z/,
    /\Adocs\/decisions\/\d{4}-[a-z0-9-]+\.md\z/,
    /\Awebsite\/README\.md\z/,
    /\Atemplates\/application\/(README|AGENTS|CLAUDE)\.md\z/,
    /\A(website\/)?vendor\//,
  ]

  CAPS = {
    "README.md"                       => 3_000,
    "AGENTS.md"                       => 3_000,
    "CLAUDE.md"                       => 200,
    "CONTRIBUTING.md"                 => 12_000,
    "website/README.md"               => 5_000,
    "templates/application/README.md" => 3_000,
    "templates/application/AGENTS.md" => 2_000,
    "templates/application/CLAUDE.md" => 200,
  }
  ADR_CAP = 10_000

  ADR_PATH   = /\Adocs\/decisions\/\d{4}-[a-z0-9-]+\.md\z/
  ADR_TITLE  = /\A# ADR (\d{4}): \S/
  ADR_DATE   = /\ADate: \d{4}-\d{2}-\d{2}\z/
  ADR_STATUS = "Status: "
  ADR_SHAPES = [%w[Decision Reasons], %w[Context Decision Reasons]]

  LINK   = /\]\(([^)\s]+)\)/
  SCHEME = /\A[a-z][a-z0-9+.-]*:/i
  VENDOR = /\A(website\/)?vendor\//

  def main : Int32
    paths = markdown_paths
    problems = [] of String
    paths.each { |path| problems.concat(homeless(path)) }
    homed = paths.select { |path| HOMES.any?(&.matches?(path)) }
    adrs = homed.select(&.matches?(ADR_PATH))
    adrs.each { |path| problems.concat(adr_problems(path)) }
    homed.each { |path| problems.concat(link_problems(path)) }
    homed.each { |path| problems.concat(cap_problems(path)) }
    Checks.fail(problems.join("\n")) unless problems.empty?
    puts "PASS: #{homed.size} markdown files sit in their homes, #{adrs.size} ADRs keep " \
         "Context, Decision and Reasons, every relative link resolves, and every file " \
         "is within its cap"
    0
  end

  # The tracked and unignored files that are markdown or live under docs/.
  private def markdown_paths : Array(String)
    listing = %w[ls-files -z --cached --others --exclude-standard]
    listed = Checks.run(["/usr/bin/git", "-C", Checks::REPO] + listing).stdout
    paths = listed.split('\0', remove_empty: true)
    paths.select! { |path| path.ends_with?(".md") || path.starts_with?("docs/") }
    paths.select! { |path| File.file?(absolute(path)) }
    paths
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
    cap = path.matches?(ADR_PATH) ? ADR_CAP : CAPS[path]?
    return [] of String unless cap
    size = File.size(absolute(path))
    return [] of String if size <= cap
    ["#{path}: #{size} bytes; its cap is #{cap} (CONTRIBUTING.md, Writing)"]
  end
end

exit Caramel::Checks::Prose.main
