require "spec"
require "../../scripts/cut/cut"

private def git(repository : String, *arguments : String) : String
  argv = ["/usr/bin/git", "-C", repository] + arguments.to_a
  result = Caramel::Latte::ProcessRunner.run(argv, timeout: 30.seconds)
  raise "git #{arguments.join(' ')}: #{result.stderr}" unless result.success?
  result.stdout
end

private def commit(repository : String, message : String) : Nil
  File.write(File.join(repository, "work.txt"), Random::Secure.hex(8))
  git(repository, "add", "--all")
  git(repository, "commit", "--quiet", "--message", message)
end

private def release_repository(&)
  repository = File.tempname("caramel-release-spec-", dir: "/private/tmp")
  Dir.mkdir(repository, 0o700)
  git(repository, "init", "--quiet")
  git(repository, "config", "user.name", "Caramel specs")
  git(repository, "config", "user.email", "specs@caramel.invalid")
  # The blank line before the terminator ends the file with a newline.
  File.write(File.join(repository, "shard.yml"), <<-YAML)
    name: caramel
    version: 0.1.0
    dependencies:
      pg:
        version: 0.30.0

    YAML
  yield repository
ensure
  FileUtils.rm_rf(repository) if repository
end

describe Caramel::Cut do
  it "reads Conventional Commits, and only them" do
    parsed = Caramel::Cut::Commit.parse("a1", "feat(frappe): add lint")
    parsed.should eq(Caramel::Cut::Commit.new("a1", "feat", "frappe", "add lint", false))
    Caramel::Cut::Commit.parse("a2", "fix!: stop").try(&.breaking).should be_true
    footer = "refactor: move\n\nBREAKING CHANGE: renamed"
    Caramel::Cut::Commit.parse("a3", footer).try(&.breaking).should be_true
    Caramel::Cut::Commit.parse("a4", "Merge branch 'x'").should be_nil
  end

  it "bumps a patch for fixes, a minor for features, and a breaking change by the 0.x rule" do
    commit = ->(type : String, breaking : Bool) do
      Caramel::Cut::Commit.new("a", type, nil, "x", breaking)
    end
    fix = commit.call("fix", false)
    docs = commit.call("docs", false)
    feature = commit.call("feat", false)
    breaking_fix = commit.call("fix", true)
    chore = commit.call("chore", false)
    zero = SemanticVersion.parse("0.3.1")
    one = SemanticVersion.parse("1.2.3")
    patch = SemanticVersion.parse("0.3.2")
    minor = SemanticVersion.parse("0.4.0")
    major = SemanticVersion.parse("2.0.0")
    Caramel::Cut.next_version(zero, [fix, docs]).should eq(patch)
    Caramel::Cut.next_version(zero, [fix, feature]).should eq(minor)
    Caramel::Cut.next_version(zero, [breaking_fix]).should eq(minor)
    Caramel::Cut.next_version(one, [breaking_fix]).should eq(major)
    Caramel::Cut.next_version(zero, [docs, chore]).should be_nil
  end

  it "finds the Unreleased notes whether or not a header precedes them" do
    changelog = "## Unreleased\n\nRun frappe setup.\n\n## 0.1.0 - 2026-09-28\n"
    parts = {"## Unreleased\n", "\nRun frappe setup.\n", "## 0.1.0 - 2026-09-28\n"}
    Caramel::Cut.split(changelog).should eq(parts)
    headed = "# Changelog\n\n## Unreleased\n"
    Caramel::Cut.split(headed).should eq({headed, "", ""})
    expect_raises(Caramel::Cut::Refused, "no ## Unreleased section") do
      Caramel::Cut.split("# Changelog\n")
    end
  end

  it "refuses a released framework migration that was edited, removed or preceded" do
    released = {1_i64 => {"create_jobs", "aa"}, 2_i64 => {"create_cache", "bb"}}
    appended = released.merge({3_i64 => {"create_runs", "cc"}})
    Caramel::Cut.check_migrations(released, appended, "v0.1.0")
    edited = {1_i64 => {"create_jobs", "aa"}, 2_i64 => {"create_cache", "zz"}}
    edit = "migration 2 create_cache shipped in v0.1.0 and was edited"
    expect_raises(Caramel::Cut::Refused, edit) do
      Caramel::Cut.check_migrations(released, edited, "v0.1.0")
    end
    removed = {1_i64 => {"create_jobs", "aa"}}
    expect_raises(Caramel::Cut::Refused, "was removed") do
      Caramel::Cut.check_migrations(released, removed, "v0.1.0")
    end
    shipped = {1_i64 => {"a", "aa"}, 5_i64 => {"b", "bb"}}
    inserted = {1_i64 => {"a", "aa"}, 3_i64 => {"c", "cc"}, 5_i64 => {"b", "bb"}}
    expect_raises(Caramel::Cut::Refused, "sort before ones v0.1.0 shipped") do
      Caramel::Cut.check_migrations(shipped, inserted, "v0.1.0")
    end
  end

  it "reads the framework migrations a release shipped, and refuses one edited since" do
    release_repository do |repository|
      output = IO::Memory.new
      source = File.join(repository, "src/caramel/cold_brew/migrations.cr")
      Dir.mkdir_p(File.dirname(source))
      migrations = ->(checksum : String) do
        <<-CR
          module Caramel::ColdBrew
            record Migration, version : Int64, name : String, checksum : String
            MIGRATIONS = [Migration.new(1_i64, "create_jobs", #{checksum.to_json})]
          end

          CR
      end
      File.write(source, migrations.call("aa"))
      commit(repository, "feat: jobs")
      Caramel::Cut.run(repository, check: ["/usr/bin/true"], output: output)
      File.write(source, migrations.call("zz"))
      commit(repository, "fix: jobs")
      edited = "migration 1 create_jobs shipped in v0.1.0 and was edited"
      expect_raises(Caramel::Cut::Refused, edited) do
        Caramel::Cut.run(repository, check: ["/usr/bin/true"], dry_run: true, output: output)
      end
    end
  end

  it "skips the migration probes only when nothing they compile changed since the tag" do
    release_repository do |repository|
      unchanged = ->(tag : String) { Caramel::Cut.migration_sources_unchanged?(repository, tag) }
      directory = File.join(repository, "src/caramel/cold_brew")
      Dir.mkdir_p(File.join(directory, "extra"))
      File.write(File.join(directory, "migrations.cr"), <<-CR)
        require "./checksums"

        module Caramel::ColdBrew
          record Migration, version : Int64, name : String, checksum : String
          MIGRATIONS = [Migration.new(1_i64, "create_jobs", CHECKSUM)]
        end

        CR
      checksums = File.join(directory, "checksums.cr")
      File.write(checksums, %(CHECKSUM = "aa"\n))
      commit(repository, "feat: jobs")
      git(repository, "tag", "v0.1.0")
      commit(repository, "fix: words")
      unchanged.call("v0.1.0").should be_true
      File.write(checksums, %(CHECKSUM = "zz"\n))
      commit(repository, "fix: checksum")
      unchanged.call("v0.1.0").should be_false

      # A wildcard require or a file-reading macro could reach a file the list
      # misses, such as one deleted since the tag, so both are always probed.
      File.write(File.join(directory, "extra/one.cr"), "# one\n")
      File.write(checksums, %(require "./extra/*"\nCHECKSUM = "zz"\n))
      commit(repository, "fix: extra")
      git(repository, "tag", "v0.1.1")
      unchanged.call("v0.1.1").should be_false
      File.write(File.join(directory, "checksum.txt"), %("zz"\n))
      File.write(checksums, <<-'CR')
        CHECKSUM = {{ read_file("#{__DIR__}/checksum.txt").id }}

        CR
      commit(repository, "fix: read")
      git(repository, "tag", "v0.1.2")
      unchanged.call("v0.1.2").should be_false
    end
  end

  it "cuts releases from the commits since the last tag, with upgrade notes, " \
     "and tags only after the checks pass" do
    release_repository do |repository|
      day = Time.utc(2026, 9, 28)
      output = IO::Memory.new
      passing = ["/usr/bin/true"]
      commit(repository, "feat: first light")
      commit(repository, "fix!: an early rename")
      Caramel::Cut.run(repository, check: passing, output: output, today: day)
      git(repository, "tag", "--list").should eq("v0.1.0\n")
      message = git(repository, "show", "--no-patch", "--format=%B", "v0.1.0")
      message.should contain("Caramel 0.1.0\n\n## 0.1.0 - 2026-09-28")
      first = File.read(File.join(repository, "CHANGELOG.md"))
      first_release = <<-MARKDOWN
        ## Unreleased

        ## 0.1.0 - 2026-09-28

        ### Features

        - first light (
        MARKDOWN
      first.should contain(first_release)
      first.should contain("### Fixes\n\n- an early rename (")
      first.should_not contain("Breaking changes")

      changelog = File.join(repository, "CHANGELOG.md")
      noted = "## Unreleased\n\nRun frappe setup after upgrading.\n"
      File.write(changelog, File.read(changelog).sub("## Unreleased\n", noted))
      commit(repository, "fix(latte): stop leaking sockets")
      commit(repository, "docs: explain the relay")
      Caramel::Cut.run(repository,
        check: passing, dry_run: true, output: output, today: day)
      output.to_s.should contain("Caramel 0.1.1 (after v0.1.0)")
      git(repository, "tag", "--list").should eq("v0.1.0\n")
      commit(repository, "feat(frappe)!: rename the dispatch")
      Caramel::Cut.run(repository, check: passing, output: output, today: day)
      manifest = File.read(File.join(repository, "shard.yml"))
      manifest.should start_with("name: caramel\nversion: 0.2.0\n")
      text = File.read(changelog)
      released = <<-MARKDOWN
        ## Unreleased

        ## 0.2.0 - 2026-09-28

        ### Upgrade notes

        Run frappe setup after upgrading.

        ### Breaking changes

        - **frappe:** rename the dispatch (
        MARKDOWN
      text.should contain(released)
      text.should contain("### Fixes\n\n- **latte:** stop leaking sockets (")
      text.should_not contain("explain the relay")
      text.should contain("## 0.1.0 - 2026-09-28")
      git(repository, "log", "-1", "--format=%s").should eq("chore(release): v0.2.0\n")

      commit(repository, "fix: one more")
      failing = ["/usr/bin/false"]
      expect_raises(Caramel::Cut::Refused, "the check suite failed") do
        Caramel::Cut.run(repository, check: failing, output: output, today: day)
      end
      git(repository, "status", "--porcelain").should be_empty
      git(repository, "tag", "--list").should eq("v0.1.0\nv0.2.0\n")

      File.write(File.join(repository, "work.txt"), "uncommitted")
      expect_raises(Caramel::Cut::Refused, "uncommitted changes") do
        Caramel::Cut.run(repository, check: passing, output: output, today: day)
      end
      git(repository, "checkout", "--", "work.txt")
      commit(repository, "docs: only words")
      git(repository, "tag", "v0.2.1")
      expect_raises(Caramel::Cut::Refused, "nothing to release") do
        Caramel::Cut.run(repository, check: passing, output: output, today: day)
      end
    end
  end

  it "refuses a release the website does not name" do
    release_repository do |repository|
      site = File.join(repository, "website/source")
      Dir.mkdir_p(site)
      File.write(File.join(site, "site.html"), "<h1>Caramel 0.1.0</h1>")
      commit(repository, "feat: first light")
      git(repository, "tag", "v0.1.0")
      commit(repository, "feat: second light")
      expect_raises(Caramel::Cut::Refused,
        "website/source/site.html does not name Caramel 0.2.0") do
        Caramel::Cut.run(repository, check: ["/usr/bin/true"], output: IO::Memory.new)
      end
      File.read(File.join(repository, "shard.yml")).should contain("version: 0.1.0\n")
      git(repository, "tag", "--list").should eq("v0.1.0\n")
    end
  end
end
