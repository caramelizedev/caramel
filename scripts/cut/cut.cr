require "json"
require "semantic_version"
require "file_utils"
require "../../src/latte/process"

# Cuts a Caramel release (ADR 0016): the next version from the Conventional
# Commits since the last tag, CHANGELOG.md from those commits and the
# hand-written notes under Unreleased, the version in shard.yml, a guard that
# released framework migrations are unchanged, and an annotated tag once the
# full check suite passes. Pushing and publishing stay manual.
module Caramel::Cut
  REPO = File.expand_path("../..", __DIR__)
  # The framework migrations, relative to a tree's root.
  MIGRATIONS_SOURCE = "src/caramel/cold_brew/migrations.cr"

  CHANGELOG = <<-MARKDOWN
    # Changelog

    Caramel follows semantic versioning. During 0.x a minor release may break compatibility and a patch release never does ([ADR 0016](docs/decisions/0016-versioning-and-releases.md)). Write upgrade notes for the next release under Unreleased; `scripts/release` moves them into its section.

    ## Unreleased

    MARKDOWN

  class Refused < Exception
  end

  # A Conventional Commit, `type(scope)!: subject`. It is breaking when marked
  # with `!` or with a BREAKING CHANGE footer.
  record Commit, hash : String, type : String, scope : String?, subject : String, breaking : Bool do
    def self.parse(hash : String, message : String) : self?
      header, _, body = message.partition('\n')
      match = header.match(/\A([a-z]+)(?:\(([^)]+)\))?(!)?: (.+)\z/) || return
      new(hash, match[1], match[2]?, match[4], !match[3]?.nil? || body.includes?("BREAKING CHANGE:"))
    end
  end

  # A fix is a patch and a feature a minor. A breaking change is a minor
  # during 0.x and a major after it. Nil when nothing warrants a release.
  def self.next_version(current : SemanticVersion, commits : Array(Commit)) : SemanticVersion?
    if commits.any?(&.breaking)
      current.major.zero? ? current.bump_minor : current.bump_major
    elsif commits.any? { |commit| commit.type == "feat" }
      current.bump_minor
    elsif commits.any? { |commit| {"fix", "perf"}.includes?(commit.type) }
      current.bump_patch
    end
  end

  # The release's changelog section: the upgrade notes, then its commits by kind.
  def self.section(version : SemanticVersion, date : Time, notes : String, commits : Array(Commit)) : String
    groups = {
      "Breaking changes" => commits.select(&.breaking),
      "Features"         => commits.select { |commit| commit.type == "feat" && !commit.breaking },
      "Fixes"            => commits.select { |commit| {"fix", "perf"}.includes?(commit.type) && !commit.breaking },
    }
    String.build do |io|
      io << "## " << version << " - " << date.to_s("%Y-%m-%d") << '\n'
      io << "\n### Upgrade notes\n\n" << notes.strip << '\n' unless notes.strip.empty?
      groups.each do |title, entries|
        next if entries.empty?
        io << "\n### " << title << "\n\n"
        entries.each { |commit| io << "- " << (commit.scope.try { |scope| "**#{scope}:** " } || "") << commit.subject << " (" << commit.hash[0, 7] << ")\n" }
      end
    end
  end

  # CHANGELOG.md split around its Unreleased notes: the text through the
  # Unreleased heading, the notes, and the earlier releases.
  def self.split(changelog : String) : {String, String, String}
    heading = "## Unreleased\n"
    start = changelog.starts_with?(heading) ? 0 : changelog.index("\n#{heading}").try(&.+(1))
    raise Refused.new("CHANGELOG.md has no ## Unreleased section") unless start
    head = changelog[0, start + heading.size]
    after = changelog[(start + heading.size)..]
    older = after.index("\n## ")
    older ? {head, after[0, older], after[(older + 1)..]} : {head, after, ""}
  end

  # Framework migrations are only appended: each one a release shipped must
  # keep its name and checksum, and new ones sort after them.
  def self.check_migrations(released : Hash(Int64, {String, String}), current : Hash(Int64, {String, String}), tag : String) : Nil
    released.each do |version, (name, checksum)|
      now = current[version]? || raise Refused.new("framework migration #{version} #{name} shipped in #{tag} and was removed; restore it")
      raise Refused.new("framework migration #{version} #{name} shipped in #{tag} and was edited; restore it and add a new migration") unless now == {name, checksum}
    end
    if newest = released.keys.max?
      inserted = current.keys.select { |version| version < newest && !released.has_key?(version) }
      raise Refused.new("framework migrations #{inserted.join(", ")} sort before ones #{tag} shipped; give them later versions") unless inserted.empty?
    end
  end

  # Whether the migration probes would print the same migrations for *tag* and
  # the working tree, so neither needs to compile: the migrations source, the
  # files under src/ it requires, and shard.lock are unchanged since *tag*.
  # The probes share the compiler, lib/ and the environment, so only those
  # files differ between them. A wildcard require or a macro that reads files
  # could reach a file the list misses, so either counts as a change, as does
  # any error.
  def self.migration_sources_unchanged?(repository : String, tag : String) : Bool
    paths = migration_sources(repository)
    return false if paths.any? { |path| reaches_unlisted_files?(File.read(File.join(repository, path))) }
    Latte::ProcessRunner.run(["/usr/bin/git", "-C", repository, "diff", "--quiet", tag, "--", "shard.lock"] + paths, timeout: 120.seconds).success?
  rescue
    false
  end

  def self.run(repository : String = REPO, check : Array(String) = [File.join(REPO, "scripts/check"), "all"], dry_run : Bool = false, output : IO = STDOUT, today : Time = Time.local) : Nil
    raise Refused.new("the working tree has uncommitted changes; commit or stash them first") unless git(repository, "status", "--porcelain").empty?
    tag = last_tag(repository)
    # Before a first release nothing shipped, so nothing it changes can break.
    commits = log(repository, tag).map { |commit| tag ? commit : commit.copy_with(breaking: false) }
    manifest = File.join(repository, "shard.yml")
    declared = SemanticVersion.parse(File.read_lines(manifest).find!(&.starts_with?("version:")).split(':', 2)[1].strip)
    # The first release is the version shard.yml already declares.
    version = tag ? next_version(SemanticVersion.parse(tag.lchop('v')), commits) : declared
    raise Refused.new("nothing to release: no features or fixes since #{tag}") unless version
    check_migrations(*shipped_and_current(repository, tag), tag) if tag && !migration_sources_unchanged?(repository, tag)
    path = File.join(repository, "CHANGELOG.md")
    head, notes, older = split(File.exists?(path) ? File.read(path) : CHANGELOG)
    section = section(version, today, notes, commits)
    if dry_run
      output.puts("Caramel #{version}#{tag ? " (after #{tag})" : " (first release)"}\n\n#{section}")
      return
    end
    File.write(manifest, File.read_lines(manifest).map { |line| line.starts_with?("version:") ? "version: #{version}" : line }.join('\n') + '\n')
    File.write(path, "#{head}\n#{section}#{older.empty? ? "" : "\n#{older}"}")
    unless Process.run(check.first, check[1..], chdir: repository, output: output, error: output).success?
      git(repository, "checkout", "--", "shard.yml")
      git(repository, "ls-files", "CHANGELOG.md").empty? ? File.delete(path) : git(repository, "checkout", "--", "CHANGELOG.md")
      raise Refused.new("the check suite failed; nothing was committed or tagged")
    end
    git(repository, "add", "shard.yml", "CHANGELOG.md")
    git(repository, "commit", "--quiet", "--message", "chore(release): v#{version}")
    git(repository, "tag", "--annotate", "--cleanup=verbatim", "v#{version}", "--message", "Caramel #{version}\n\n#{section}")
    output.puts("Tagged v#{version}. Publish it:\n  git push origin HEAD v#{version}\n  gh release create v#{version} --verify-tag --title \"Caramel #{version}\" --notes-from-tag")
  end

  private def self.last_tag(repository : String) : String?
    result = Latte::ProcessRunner.run(["/usr/bin/git", "-C", repository, "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*"], timeout: 30.seconds)
    result.success? ? result.stdout.strip : nil
  end

  private def self.log(repository : String, tag : String?) : Array(Commit)
    entries = git(repository, "log", "--reverse", "--format=%H%x1f%B%x1e", tag ? "#{tag}..HEAD" : "HEAD")
    entries.split('\u{1e}', remove_empty: true).compact_map do |entry|
      hash, _, message = entry.strip.partition('\u{1f}')
      Commit.parse(hash, message.strip) unless hash.empty?
    end
  end

  # The migrations source and every file under src/ it requires, directly or
  # not, relative to *repository*.
  private def self.migration_sources(repository : String) : Array(String)
    # --verbose also lists the files the tool did not follow, such as lib/ and
    # the standard library, which the probes share.
    result = Latte::ProcessRunner.run([File.join(REPO, "scripts/crystal"), "tool", "dependencies", File.join(repository, MIGRATIONS_SOURCE), "--format", "flat", "--verbose"], chdir: REPO, timeout: 120.seconds, output_limit: 1024 * 1024)
    raise Refused.new("could not list the files the framework migrations require: #{result.stderr.strip}") unless result.success?
    source = File.join(repository, "src", "")
    result.stdout.lines.compact_map do |line|
      entry = line.rchop(" duplicate skipped")
      path = File.expand_path(entry.rchop(" filtered"), REPO)
      next unless path.starts_with?(source)
      raise Refused.new("#{path} was not followed") if entry.ends_with?(" filtered")
      Path[path].relative_to(repository).to_s
    end.push(MIGRATIONS_SOURCE).uniq
  end

  private def self.reaches_unlisted_files?(source : String) : Bool
    source.matches?(/\brequire\s+"[^"]*\*/) ||
      source.scan(/\{\{.*?\}\}|\{%.*?%\}/m).any?(&.[0].matches?(/\b(?:read_file|run|system)\b|`/))
  end

  # The framework migrations *tag* shipped and the working tree's. The two
  # probes are separate programs, so they compile side by side; when both
  # fail, the tag's error is raised.
  private def self.shipped_and_current(repository : String, tag : String) : {Hash(Int64, {String, String}), Hash(Int64, {String, String})}
    shipped = Channel(Hash(Int64, {String, String}) | Exception).new(1)
    spawn do
      shipped.send(migrations(repository, tag))
    rescue ex
      shipped.send(ex)
    end
    current = begin
      migrations(repository, nil)
    rescue ex
      ex
    end
    released = shipped.receive
    raise released if released.is_a?(Exception)
    raise current if current.is_a?(Exception)
    {released, current}
  end

  # The framework migrations in *tag*'s tree, or in the working tree, by
  # compiling a probe against them. A tree without them ships none.
  private def self.migrations(repository : String, tag : String?) : Hash(Int64, {String, String})
    work = File.tempname("caramel-release-", dir: "/private/tmp")
    Dir.mkdir(work, 0o700)
    begin
      tree = repository
      if tag
        return {} of Int64 => {String, String} if git(repository, "ls-tree", "--name-only", tag, "--", MIGRATIONS_SOURCE).empty?
        tree = File.join(work, "tree")
        Dir.mkdir(tree)
        archive = File.join(work, "tree.tar")
        # The probe reads only src/.
        git(repository, "archive", "--output", archive, tag, "src")
        # A tree that failed to extract would look like one without migrations.
        extracted = Latte::ProcessRunner.run(["/usr/bin/tar", "-xf", archive, "-C", tree], timeout: 120.seconds)
        raise Refused.new("could not extract #{tag} to read its framework migrations: #{extracted.diagnostic}") unless extracted.success?
      end
      source = File.join(tree, MIGRATIONS_SOURCE)
      return {} of Int64 => {String, String} unless File.exists?(source)
      # Crystal resolves a file require only relative to the requiring file,
      # so the probe names the migrations by their path relative to itself.
      probe = File.join(work, "probe.cr")
      relative = Path[source].relative_to(work).to_s
      relative = "./#{relative}" unless relative.starts_with?("../")
      File.write(probe, %(require #{relative.to_json}\nrequire "json"\nputs Caramel::ColdBrew::MIGRATIONS.map { |migration| [migration.version.to_s, migration.name, migration.checksum] }.to_json\n))
      # Each probe links its own executable: `crystal run` links every
      # probe.cr to one temporary file in the shared compiler cache.
      executable = File.join(work, "probe")
      result = Latte::ProcessRunner.run([File.join(REPO, "scripts/crystal"), "build", probe, "-o", executable], chdir: REPO, timeout: 600.seconds, output_limit: 1024 * 1024)
      result = Latte::ProcessRunner.run([executable], chdir: REPO, timeout: 60.seconds, output_limit: 1024 * 1024) if result.success?
      raise Refused.new("could not read the framework migrations of #{tag || "the working tree"}: #{result.stderr.strip}") unless result.success?
      Array(Array(String)).from_json(result.stdout).to_h { |(version, name, checksum)| {version.to_i64, {name, checksum}} }
    ensure
      FileUtils.rm_rf(work)
    end
  end

  private def self.git(repository : String, *arguments : String) : String
    result = Latte::ProcessRunner.run(["/usr/bin/git", "-C", repository] + arguments.to_a, timeout: 120.seconds, output_limit: 16 * 1024 * 1024)
    raise Refused.new("git #{arguments.first} failed: #{result.stderr.strip}") unless result.success?
    result.stdout
  end
end
