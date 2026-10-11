require "file_utils"
require "random/secure"
require "yaml"
require "../latte/paths"
require "../latte/process"
require "./dev_files"
require "./project"

module Caramel::Frappe
  # `frappe build`: compiles the committed tree in a pinned Linux container and
  # writes a tarball of a static linux/amd64 binary and `public/` (ADR 0032).
  class ReleaseBuild
    IMAGE = "crystallang/crystal:1.21.1-alpine@sha256:" \
            "bf35489a8273a606368bd6a7ab2e24d01f950ca919c85ba4fe4c5bf10cd7a67e"
    PLATFORM = "linux/amd64"
    ARTIFACT = /\A[a-z][a-z0-9_]*-\d{8}T\d{6}Z-[0-9a-f]{7}-linux-amd64\.tar\.gz\z/
    SHARD    = /\A[a-z][a-z0-9_]*\z/
    GIT      = "/usr/bin/git"
    TAR      = "/usr/bin/tar"
    # Runs in the container with the entry point, the shard and the artifact's
    # name as $1, $2 and $3. Debug info stays, for Crema's backtraces.
    SCRIPT = <<-SH
      shards install --frozen --without-development
      mkdir -p /work/stage/bin
      crystal build "$1" --release --static -o "/work/stage/bin/$2"
      if [ -d public ]; then cp -R public /work/stage/public; else mkdir -p /work/stage/public; fi
      tar -czf "/work/$3" -C /work/stage bin public
      SH
    DIRTY = "The working tree has uncommitted changes; commit or stash them, " \
            "then run frappe build:"
    PUBLISHED = "Publishing app/assets changed tracked files; commit them, " \
                "then run frappe build:"

    def initialize(@project : Project, @log : IO, @now : Time = Time.utc)
    end

    # Builds the artifact from HEAD and returns its absolute path.
    def run : String
      root = @project.root
      prefix = repository_prefix(root)
      require_clean(root, DIRTY)
      DevFiles.new(root).publish_assets
      require_clean(root, PUBLISHED)
      docker = Process.find_executable("docker") ||
               raise Error.new("frappe build needs Docker: put docker on PATH, " \
                               "for example by starting Docker Desktop")
      shard = shard_name(root)
      sha7 = git!(root, "rev-parse", "--short=7", "HEAD")
      artifact = self.class.artifact_name(shard, @now, sha7)
      state = Latte::StateSecurity.ensure_owned_directory(File.join(root, ".caramel"))
      build = File.join(state, "build")
      Dir.mkdir_p(build)
      work = File.join(build, "work-#{Random::Secure.hex(4)}")
      begin
        export(root, prefix, work)
        compile(docker, root, work, shard, artifact)
        File.rename(File.join(work, artifact), File.join(build, artifact))
      ensure
        FileUtils.rm_rf(work)
      end
      File.join(build, artifact)
    end

    # Such as `shop-20261011T090507Z-abc1234-linux-amd64.tar.gz`.
    def self.artifact_name(shard : String, time : Time, sha7 : String) : String
      "#{shard}-#{time.to_s("%Y%m%dT%H%M%SZ")}-#{sha7}-linux-amd64.tar.gz"
    end

    # The `path` dependencies in *manifest*, a shard.yml under *root*, as host
    # paths and the paths the container's /work/source resolves them to.
    def self.path_mounts(manifest : String, root : String) : Array({String, String})
      mounts = [] of {String, String}
      dependencies = YAML.parse(manifest)["dependencies"]?.try(&.as_h?) || return mounts
      dependencies.each do |name, entry|
        path = entry.as_h?.try(&.["path"]?).try(&.as_s?) || next
        host = File.expand_path(path, root)
        unless File.exists?(host)
          raise Error.new("Path dependency #{name} points to #{path}, which does not exist")
        end
        mounts << {host, File.expand_path(path, "/work/source")}
      end
      mounts
    end

    def self.container_arguments(work : String,
                                 mounts : Array({String, String}),
                                 entrypoint : String,
                                 shard : String,
                                 artifact : String) : Array(String)
      arguments = ["run", "--rm", "--platform", PLATFORM, "-v", "#{work}:/work"]
      mounts.each { |host, container| arguments.push("-v", "#{host}:#{container}:ro") }
      arguments + ["-w", "/work/source", IMAGE, "sh", "-euc", SCRIPT, "sh",
                   entrypoint, shard, artifact]
    end

    # The project's directory inside its repository, such as `apps/shop/`.
    private def repository_prefix(root : String) : String
      prefix = git(root, "rev-parse", "--show-prefix")
      unless prefix.success? && git(root, "rev-parse", "--verify", "HEAD").success?
        raise Error.new("frappe build needs a git repository with a commit; " \
                        "run git init and commit first")
      end
      prefix.stdout.strip
    end

    private def require_clean(root : String, message : String) : Nil
      status = git(root, "status", "--porcelain", "--untracked-files=normal", "--", ".")
      raise Error.new("git status failed: #{status.stderr.strip}") unless status.success?
      changes = status.stdout.rstrip
      raise Error.new("#{message}\n#{changes}") unless changes.empty?
    end

    private def shard_name(root : String) : String
      name = YAML.parse(File.read(File.join(root, "shard.yml")))["name"]?.try(&.as_s?)
      unless name && name.matches?(SHARD)
        raise Error.new("shard.yml's name must be lowercase letters, digits and underscores")
      end
      name
    end

    # HEAD's tree under *prefix*, unpacked into *work*/source beside an empty stage.
    private def export(root : String, prefix : String, work : String) : Nil
      source = File.join(work, "source")
      Dir.mkdir_p(source)
      Dir.mkdir_p(File.join(work, "stage"))
      archive = File.join(work, "source.tar")
      git!(root, "archive", "--format=tar", "-o", archive, "HEAD:#{prefix}")
      unpacked = Latte::ProcessRunner.run([TAR, "-xf", archive, "-C", source], timeout: 2.minutes)
      raise Error.new("Could not unpack the committed tree") unless unpacked.success?
      File.delete(archive)
    end

    # Runs the build script in the pinned image with the user's environment, so
    # that `docker` finds its context and credentials.
    private def compile(docker : String, root : String, work : String,
                        shard : String, artifact : String) : Nil
      mounts = self.class.path_mounts(File.read(File.join(root, "shard.yml")), root)
      arguments = self.class.container_arguments(work, mounts, @project.entrypoint, shard,
        artifact)
      @log.puts "Building #{artifact} in crystallang/crystal:1.21.1-alpine for #{PLATFORM}"
      status = Process.run(docker, arguments, output: @log, error: @log)
      return if status.success?
      raise Error.new("The container build failed (exit #{status.exit_code}); " \
                      "see the output above")
    end

    private def git(root : String, *arguments : String) : Latte::ProcessResult
      Latte::ProcessRunner.run([GIT, "-C", root] + arguments.to_a, timeout: 60.seconds)
    end

    # The trimmed output of a git command that must succeed.
    private def git!(root : String, *arguments : String) : String
      result = git(root, *arguments)
      return result.stdout.strip if result.success?
      raise Error.new("git #{arguments.first} failed: #{result.stderr.strip}")
    end
  end
end
