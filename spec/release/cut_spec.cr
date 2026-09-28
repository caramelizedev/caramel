require "spec"
require "../../scripts/cut/cut"

private def git(repository : String, *arguments : String) : String
  result = Caramel::Latte::ProcessRunner.run(["/usr/bin/git", "-C", repository] + arguments.to_a, timeout: 30.seconds)
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
  File.write(File.join(repository, "shard.yml"), "name: caramel\nversion: 0.1.0\ndependencies:\n  pg:\n    version: 0.30.0\n")
  yield repository
ensure
  FileUtils.rm_rf(repository) if repository
end

describe Caramel::Cut do
  it "reads Conventional Commits, and only them" do
    Caramel::Cut::Commit.parse("a1", "feat(frappe): add lint").should eq(Caramel::Cut::Commit.new("a1", "feat", "frappe", "add lint", false))
    Caramel::Cut::Commit.parse("a2", "fix!: stop").try(&.breaking).should be_true
    Caramel::Cut::Commit.parse("a3", "refactor: move\n\nBREAKING CHANGE: renamed").try(&.breaking).should be_true
    Caramel::Cut::Commit.parse("a4", "Merge branch 'x'").should be_nil
  end

  it "bumps a patch for fixes, a minor for features, and a breaking change by the 0.x rule" do
    commit = ->(type : String, breaking : Bool) { Caramel::Cut::Commit.new("a", type, nil, "x", breaking) }
    zero = SemanticVersion.parse("0.3.1")
    Caramel::Cut.next_version(zero, [commit.call("fix", false), commit.call("docs", false)]).should eq(SemanticVersion.parse("0.3.2"))
    Caramel::Cut.next_version(zero, [commit.call("fix", false), commit.call("feat", false)]).should eq(SemanticVersion.parse("0.4.0"))
    Caramel::Cut.next_version(zero, [commit.call("fix", true)]).should eq(SemanticVersion.parse("0.4.0"))
    Caramel::Cut.next_version(SemanticVersion.parse("1.2.3"), [commit.call("fix", true)]).should eq(SemanticVersion.parse("2.0.0"))
    Caramel::Cut.next_version(zero, [commit.call("docs", false), commit.call("chore", false)]).should be_nil
  end

  it "finds the Unreleased notes whether or not a header precedes them" do
    Caramel::Cut.split("## Unreleased\n\nRun frappe setup.\n\n## 0.1.0 - 2026-09-28\n").should eq({"## Unreleased\n", "\nRun frappe setup.\n", "## 0.1.0 - 2026-09-28\n"})
    Caramel::Cut.split("# Changelog\n\n## Unreleased\n").should eq({"# Changelog\n\n## Unreleased\n", "", ""})
    expect_raises(Caramel::Cut::Refused, "no ## Unreleased section") { Caramel::Cut.split("# Changelog\n") }
  end

  it "refuses a released framework migration that was edited, removed or preceded" do
    released = {1_i64 => {"create_jobs", "aa"}, 2_i64 => {"create_cache", "bb"}}
    Caramel::Cut.check_migrations(released, released.merge({3_i64 => {"create_runs", "cc"}}), "v0.1.0")
    expect_raises(Caramel::Cut::Refused, "migration 2 create_cache shipped in v0.1.0 and was edited") do
      Caramel::Cut.check_migrations(released, {1_i64 => {"create_jobs", "aa"}, 2_i64 => {"create_cache", "zz"}}, "v0.1.0")
    end
    expect_raises(Caramel::Cut::Refused, "was removed") { Caramel::Cut.check_migrations(released, {1_i64 => {"create_jobs", "aa"}}, "v0.1.0") }
    expect_raises(Caramel::Cut::Refused, "sort before ones v0.1.0 shipped") do
      Caramel::Cut.check_migrations({1_i64 => {"a", "aa"}, 5_i64 => {"b", "bb"}}, {1_i64 => {"a", "aa"}, 3_i64 => {"c", "cc"}, 5_i64 => {"b", "bb"}}, "v0.1.0")
    end
  end

  it "reads the framework migrations a release shipped, and refuses one edited since" do
    release_repository do |repository|
      output = IO::Memory.new
      source = File.join(repository, "src/caramel/cold_brew/migrations.cr")
      Dir.mkdir_p(File.dirname(source))
      migrations = ->(checksum : String) do
        "module Caramel::ColdBrew\n  record Migration, version : Int64, name : String, checksum : String\n  MIGRATIONS = [Migration.new(1_i64, \"create_jobs\", #{checksum.to_json})]\nend\n"
      end
      File.write(source, migrations.call("aa"))
      commit(repository, "feat: jobs")
      Caramel::Cut.run(repository, check: ["/usr/bin/true"], output: output)
      File.write(source, migrations.call("zz"))
      commit(repository, "fix: jobs")
      expect_raises(Caramel::Cut::Refused, "migration 1 create_jobs shipped in v0.1.0 and was edited") do
        Caramel::Cut.run(repository, check: ["/usr/bin/true"], dry_run: true, output: output)
      end
    end
  end

  it "cuts releases from the commits since the last tag, with upgrade notes, and tags only after the checks pass" do
    release_repository do |repository|
      day = Time.utc(2026, 9, 28)
      output = IO::Memory.new
      commit(repository, "feat: first light")
      commit(repository, "fix!: an early rename")
      Caramel::Cut.run(repository, check: ["/usr/bin/true"], output: output, today: day)
      git(repository, "tag", "--list").should eq("v0.1.0\n")
      git(repository, "show", "--no-patch", "--format=%B", "v0.1.0").should contain("Caramel 0.1.0\n\n## 0.1.0 - 2026-09-28")
      first = File.read(File.join(repository, "CHANGELOG.md"))
      first.should contain("## Unreleased\n\n## 0.1.0 - 2026-09-28\n\n### Features\n\n- first light (")
      first.should contain("### Fixes\n\n- an early rename (")
      first.should_not contain("Breaking changes")

      changelog = File.join(repository, "CHANGELOG.md")
      File.write(changelog, File.read(changelog).sub("## Unreleased\n", "## Unreleased\n\nRun frappe setup after upgrading.\n"))
      commit(repository, "fix(latte): stop leaking sockets")
      commit(repository, "docs: explain the relay")
      Caramel::Cut.run(repository, check: ["/usr/bin/true"], dry_run: true, output: output, today: day)
      output.to_s.should contain("Caramel 0.1.1 (after v0.1.0)")
      git(repository, "tag", "--list").should eq("v0.1.0\n")
      commit(repository, "feat(frappe)!: rename the dispatch")
      Caramel::Cut.run(repository, check: ["/usr/bin/true"], output: output, today: day)
      File.read(File.join(repository, "shard.yml")).should start_with("name: caramel\nversion: 0.2.0\n")
      text = File.read(changelog)
      text.should contain("## Unreleased\n\n## 0.2.0 - 2026-09-28\n\n### Upgrade notes\n\nRun frappe setup after upgrading.\n\n### Breaking changes\n\n- **frappe:** rename the dispatch (")
      text.should contain("### Fixes\n\n- **latte:** stop leaking sockets (")
      text.should_not contain("explain the relay")
      text.should contain("## 0.1.0 - 2026-09-28")
      git(repository, "log", "-1", "--format=%s").should eq("chore(release): v0.2.0\n")

      commit(repository, "fix: one more")
      expect_raises(Caramel::Cut::Refused, "the check suite failed") { Caramel::Cut.run(repository, check: ["/usr/bin/false"], output: output, today: day) }
      git(repository, "status", "--porcelain").should be_empty
      git(repository, "tag", "--list").should eq("v0.1.0\nv0.2.0\n")

      File.write(File.join(repository, "work.txt"), "uncommitted")
      expect_raises(Caramel::Cut::Refused, "uncommitted changes") { Caramel::Cut.run(repository, check: ["/usr/bin/true"], output: output, today: day) }
      git(repository, "checkout", "--", "work.txt")
      commit(repository, "docs: only words")
      git(repository, "tag", "v0.2.1")
      expect_raises(Caramel::Cut::Refused, "nothing to release") { Caramel::Cut.run(repository, check: ["/usr/bin/true"], output: output, today: day) }
    end
  end
end
