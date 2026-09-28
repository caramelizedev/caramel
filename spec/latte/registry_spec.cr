require "spec"
require "file_utils"
require "json"
require "../../src/latte/registry"

private def latte_temp_root : String
  root = File.join(Dir.tempdir, "caramel-latte-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir(root, 0o700)
  root
end

private def remove_latte_root(root : String)
  begin
    paths = Caramel::Latte::Paths.new(root)
    FileUtils.rm_rf(paths.run_dir)
  rescue
  end
  FileUtils.rm_rf(root)
end

describe Caramel::Latte::Paths do
  it "uses an explicit root and creates private durable and shortened runtime paths" do
    root = latte_temp_root
    begin
      paths = Caramel::Latte::Paths.new(root)

      paths.root.should eq(File.realpath(root))
      paths.run_dir.should match(%r{\A/private/tmp/caramel-\d+-[0-9a-f]{12}\z})
      paths.run_dir.size.should be < 80
      paths.control_socket.size.should be < 104
      paths.site_run_dir("0123456789abcdef").size.should be < 104
      paths.postgres_socket_dir.size.should be < 104

      [
        paths.run_dir,
        paths.site_run_dir("0123456789abcdef"),
        paths.postgres_socket_dir,
        paths.secrets_dir,
        paths.logs_dir,
        paths.dns_dir,
        paths.caddy_dir,
      ].each do |directory|
        File.info(directory).directory?.should be_true
        File.info(directory).permissions.value.should eq(0o700)
        File.info(directory).owner_id.should eq(File.info(root).owner_id)
      end
    ensure
      remove_latte_root(root)
    end
  end

  it "rejects symlinked or foreign-owned managed paths" do
    root = latte_temp_root
    alias_path = "#{root}-alias"
    begin
      File.symlink(root, alias_path)
      expect_raises(ArgumentError) { Caramel::Latte::Paths.new(alias_path) }
    ensure
      FileUtils.rm_rf(alias_path)
      remove_latte_root(root)
    end
  end

  it "does not normalize a symlink encountered at a newly created component" do
    root = latte_temp_root
    linked = File.join(root, "linked")
    begin
      File.symlink(root, linked)
      expect_raises(ArgumentError) do
        Caramel::Latte::StateSecurity.ensure_owned_directory(linked)
      end
      File.info(root, follow_symlinks: false).permissions.value.should eq(0o700)
      File.info(linked, follow_symlinks: false).symlink?.should be_true
    ensure
      remove_latte_root(root)
    end
  end

  it "rejects empty roots without changing the current directory permissions" do
    cwd = Dir.current
    mode_before = File.info(cwd, follow_symlinks: false).permissions.value
    previous = ENV["CARAMEL_HOME"]?
    begin
      ENV["CARAMEL_HOME"] = ""
      expect_raises(ArgumentError) { Caramel::Latte::Paths.new }
      expect_raises(ArgumentError) { Caramel::Latte::Paths.new("") }
      expect_raises(ArgumentError) { Caramel::Latte::Paths.new("   ") }
      File.info(cwd, follow_symlinks: false).permissions.value.should eq(mode_before)
    ensure
      if previous
        ENV["CARAMEL_HOME"] = previous
      else
        ENV.delete("CARAMEL_HOME")
      end
    end
  end
end

describe Caramel::Latte::Site do
  it "validates names, canonicalizes an existing project directory, and derives origins" do
    root = latte_temp_root
    project = File.join(root, "project")
    alias_path = File.join(root, "project-alias")
    begin
      Dir.mkdir(project, 0o700)
      File.symlink(project, alias_path)

      site = Caramel::Latte::Site.new("bookshelf", alias_path)
      site.name.should eq("bookshelf")
      site.directory.should eq(File.realpath(project))
      site.suffix.should eq("caramel")
      site.domain.should eq("bookshelf.caramel")
      site.origin.should eq("https://bookshelf.caramel")
      site.id.should match(/\A[0-9a-f]{16}\z/)
      site.id.should eq(Caramel::Latte::Site.new("bookshelf", project).id)

      ["", "1bookshelf", "Bookshelf", "bookshelf_", "bookshelf-", "a" * 64, "book\n"].each do |name|
        expect_raises(ArgumentError) { Caramel::Latte::Site.new(name, project) }
      end
    ensure
      remove_latte_root(root)
    end
  end

  it "allows the explicit test and localhost suffixes and rejects other suffixes" do
    root = latte_temp_root
    begin
      site = Caramel::Latte::Site.new("bookshelf", root, suffix: ".test")
      site.suffix.should eq("test")
      site.domain.should eq("bookshelf.test")
      site.origin.should eq("https://bookshelf.test")
      local = Caramel::Latte::Site.new("bookshelf", root, suffix: "localhost")
      local.domain.should eq("bookshelf.localhost")
      local.id.should_not eq(site.id)
      expect_raises(ArgumentError) { Caramel::Latte::Site.new("bookshelf", root, suffix: "example") }
      expect_raises(ArgumentError) { Caramel::Latte::Site.new("bookshelf", root, suffix: "local") }
    ensure
      remove_latte_root(root)
    end
  end
end

describe Caramel::Latte::Registry do
  it "registers idempotently by canonical name, directory, and suffix" do
    root = latte_temp_root
    project = File.join(root, "project")
    alias_path = File.join(root, "project-alias")
    begin
      Dir.mkdir(project, 0o700)
      File.symlink(project, alias_path)
      registry = Caramel::Latte::Registry.new(root)

      first = registry.register("bookshelf", alias_path)
      second = registry.register(name: "bookshelf", directory: project)
      second.should eq(first)
      registry.find("bookshelf").should eq(first)
      registry.find(first.id).should eq(first)
      registry.list.should eq([first])

      document = JSON.parse(File.read(registry.registry_file))
      document["version"].as_i.should eq(1)
      document["sites"].as_a.size.should eq(1)
      File.info(registry.registry_file).permissions.value.should eq(0o600)
      File.read(registry.registry_file).should_not contain("password")
      File.read(registry.registry_file).should_not contain("secret")
    ensure
      remove_latte_root(root)
    end
  end

  it "rejects name and directory collisions without mutating the registry" do
    root = latte_temp_root
    first_directory = File.join(root, "one")
    second_directory = File.join(root, "two")
    begin
      Dir.mkdir(first_directory, 0o700)
      Dir.mkdir(second_directory, 0o700)
      registry = Caramel::Latte::Registry.new(root)
      first = registry.register("bookshelf", first_directory)
      before = File.read(registry.registry_file)

      expect_raises(ArgumentError) { registry.register("bookshelf", second_directory) }
      expect_raises(ArgumentError) { registry.register("another", first_directory) }
      File.read(registry.registry_file).should eq(before)
      registry.list.should eq([first])
    ensure
      remove_latte_root(root)
    end
  end

  it "refuses a newer registry format and corrupt registries without resetting data" do
    root = latte_temp_root
    begin
      registry = Caramel::Latte::Registry.new(root)
      # A newer format may add keys; it is refused as newer, not as corrupt.
      original = %({"version":2,"sites":[],"aliases":[]})
      File.write(registry.registry_file, original)
      File.chmod(registry.registry_file, 0o600)
      expect_raises(Caramel::Latte::StateFormat::Newer, "written by a newer Caramel (format 2); Caramel #{Caramel::VERSION} reads format 1") { registry.list }
      File.read(registry.registry_file).should eq(original)

      malformed = "{not json"
      File.write(registry.registry_file, malformed)
      File.chmod(registry.registry_file, 0o600)
      expect_raises(ArgumentError) { registry.list }
      File.read(registry.registry_file).should eq(malformed)
    ensure
      remove_latte_root(root)
    end
  end

  it "preserves project data when unregistering and validates private upstream sockets" do
    root = latte_temp_root
    project = File.join(root, "project")
    begin
      Dir.mkdir(project, 0o700)
      File.write(File.join(project, "important.db"), "keep me")
      registry = Caramel::Latte::Registry.new(root)
      site = registry.register("bookshelf", project)
      socket_directory = registry.paths.site_run_dir(site.id)
      socket = File.join(socket_directory, "app.sock")
      # The managed path boundary is exercised here with a regular file;
      # production callers must provide an actual Unix socket and are rejected
      # before any route is persisted.
      File.write(socket, "not a socket")
      File.chmod(socket, 0o600)

      expect_raises(ArgumentError) { registry.validate_upstream(site.id, socket) }
      expect_raises(ArgumentError) { registry.validate_upstream(site.id, File.join(root, "outside.sock")) }
      expect_raises(ArgumentError) { registry.validate_upstream(site.id, File.join(socket_directory, "..", "other.sock")) }
      File.symlink(socket, File.join(socket_directory, "alias.sock"))
      expect_raises(ArgumentError) { registry.validate_upstream(site.id, File.join(socket_directory, "alias.sock")) }
      File.chmod(socket, 0o666)
      expect_raises(ArgumentError) { registry.validate_upstream(site.id, socket) }

      registry.unregister(site.id).should eq(site)
      File.exists?(File.join(project, "important.db")).should be_true
      registry.list.should be_empty
    ensure
      remove_latte_root(root)
    end
  end

  it "keeps concurrent registrations from losing updates" do
    root = latte_temp_root
    first_directory = File.join(root, "one")
    second_directory = File.join(root, "two")
    begin
      Dir.mkdir(first_directory, 0o700)
      Dir.mkdir(second_directory, 0o700)
      registry = Caramel::Latte::Registry.new(root)
      started = Channel(Nil).new
      release = Channel(Nil).new
      finished = Channel(Nil).new
      [
        {"one", first_directory},
        {"two", second_directory},
      ].map do |name, directory|
        spawn do
          started.send(nil)
          release.receive
          Caramel::Latte::Registry.new(root).register(name, directory)
          finished.send(nil)
        end
      end
      2.times { started.receive }
      2.times { release.send(nil) }
      2.times { finished.receive }
      registry.list.map(&.name).sort!.should eq(["one", "two"])
    ensure
      remove_latte_root(root)
    end
  end
end
