require "spec"
require "file_utils"
require "../../src/frappe/project"

private def project_fixture(&)
  root = File.tempname("caramel-project-")
  Dir.mkdir(root)
  Dir.mkdir(File.join(root, "config"))
  File.write(File.join(root, "shard.lock"), "version: 2.0\nshards:\n  caramel:\n    path: /private/tmp/caramel\n    version: #{Caramel::VERSION}\n")
  File.write(File.join(root, "config/environment.yml"), <<-YAML)
    version: 1
    name: bookshelf
    postgresql_major: 18
    extensions: []
    domain_suffix: caramel
    YAML
  yield root
ensure
  FileUtils.rm_rf(root) if root
end

describe Caramel::Frappe::Project do
  it "loads versioned metadata without creating local state" do
    project_fixture do |root|
      before = Dir.children(root).sort
      project = Caramel::Frappe::Project.load(root)
      project.name.should eq("bookshelf")
      project.origin.should eq("https://bookshelf.caramel")
      project.module_name.should eq("Bookshelf")
      project.shard_name.should eq("bookshelf")
      project.metadata.postgresql_major.should eq(18)
      project.metadata.extensions.should be_empty
      Dir.children(root).sort.should eq(before)
    end
  end

  it "rejects another pinned release, a lock without caramel and unknown manifest fields" do
    project_fixture do |root|
      lock = File.join(root, "shard.lock")
      original = File.read(lock)
      File.write(lock, original.sub("version: #{Caramel::VERSION}", "version: 9.0.0"))
      expect_raises(Caramel::Frappe::Error, "This project uses Caramel 9.0.0, not #{Caramel::VERSION}") { Caramel::Frappe::Project.load(root) }
      File.write(lock, "version: 2.0\nshards:\n  db:\n    git: https://github.com/crystal-lang/crystal-db.git\n    version: 0.14.0\n")
      expect_raises(Caramel::Frappe::Error, "shard.lock does not pin caramel") { Caramel::Frappe::Project.load(root) }
      File.write(lock, original)
      File.open(File.join(root, "config/environment.yml"), "a") { |io| io.puts("secret: do-not-accept-here") }
      expect_raises(Caramel::Frappe::Error, "environment.yml") { Caramel::Frappe::Project.load(root) }
    end
  end

  it "accepts an explicit test suffix and validates identifiers and PostgreSQL major" do
    project_fixture do |root|
      path = File.join(root, "config/environment.yml")
      original = File.read(path)
      File.write(path, original.gsub("bookshelf", "reading-list").gsub("caramel", "test"))
      project = Caramel::Frappe::Project.load(root)
      project.origin.should eq("https://reading-list.test")
      project.module_name.should eq("ReadingList")
      project.shard_name.should eq("reading_list")
      File.write(path, original.gsub("caramel", ".test"))
      Caramel::Frappe::Project.load(root).origin.should eq("https://bookshelf.test")
      [original.gsub("18", "17"), original.gsub("caramel", "com"), original.gsub("bookshelf", "../../outside")].each do |invalid|
        File.write(path, invalid)
        expect_raises(Caramel::Frappe::Error) { Caramel::Frappe::Project.load(root) }
      end
    end
  end

  it "writes local values privately, preserves existing secrets and regenerates them for a clone" do
    project_fixture do |root|
      project = Caramel::Frappe::Project.load(root)
      connections = {"DATABASE_URL" => "postgresql://runtime:password@/development?host=%2Ftmp%2Fpg", "SPEC_DATABASE_URL" => "postgresql://spec:password@/bookshelf_spec?host=%2Ftmp%2Fpg"}
      first = project.ensure_local_environment(connections)
      first["APP_SECRET"].bytesize.should eq(64)
      first["APP_ORIGIN"].should eq(project.origin)
      File.info(File.join(root, ".env")).permissions.value.should eq(0o600)
      # Interrupted writes may leave staging files; keep that location private
      # and under the generated project's ignored state directory.
      File.info(File.join(root, ".caramel")).permissions.value.should eq(0o700)
      Dir.children(File.join(root, ".caramel")).should be_empty
      project.ensure_local_environment(connections)["APP_SECRET"].should eq(first["APP_SECRET"])
      File.delete(File.join(root, ".env"))
      project.ensure_local_environment(connections)["APP_SECRET"].should_not eq(first["APP_SECRET"])
    end
  end

  it "refuses to overwrite conflicting credentials or read nonprivate local secrets" do
    project_fixture do |root|
      project = Caramel::Frappe::Project.load(root)
      project.ensure_local_environment({"DATABASE_URL" => "original"})
      original = File.read(File.join(root, ".env"))
      expect_raises(Caramel::Frappe::Error, "differs") { project.ensure_local_environment({"DATABASE_URL" => "replacement"}) }
      File.read(File.join(root, ".env")).should eq(original)
      File.chmod(File.join(root, ".env"), 0o644)
      expect_raises(Caramel::Frappe::Error, "0600") { project.local_environment }
    end
  end

  it "refuses symlinked secrets without changing the target" do
    project_fixture do |root|
      target = File.join(root, "private-env")
      File.write(target, "APP_SECRET=keep\n")
      File.chmod(target, 0o600)
      File.symlink(target, File.join(root, ".env"))
      expect_raises(Caramel::Frappe::Error, "regular") { Caramel::Frappe::Project.load(root).local_environment }
      File.read(target).should eq("APP_SECRET=keep\n")
    end
  end
end

describe Caramel::Frappe::LocalEnvironment do
  it "roundtrips values literally without shell interpolation" do
    values = {"APP_SECRET" => "s" * 64, "SPECIAL" => "$(touch /tmp/never-run) ${HOME} `whoami` # literal\nsecond line", "URL" => "https://bookshelf.caramel?a=b&c=d"}
    Caramel::Frappe::LocalEnvironment.parse(Caramel::Frappe::LocalEnvironment.dump(values)).should eq(values)
    Caramel::Frappe::LocalEnvironment.parse("# comment\nA=plain\nB='literal value'\n\n").should eq({"A" => "plain", "B" => "literal value"})
  end

  it "rejects duplicate keys, malformed quoting and invalid names" do
    ["A=first\nA=second\n", "A=\"unclosed\n", "bad-name=value\n", "A=\u0000\n"].each do |invalid|
      expect_raises(Caramel::Frappe::Error) { Caramel::Frappe::LocalEnvironment.parse(invalid) }
    end
  end
end
