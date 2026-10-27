require "digest/sha256"
require "file_utils"
require "json"
require "random/secure"
require "yaml"
require "../latte/paths"
require "../latte/process"
require "./dev_files"
require "./project"

module Caramel::Frappe
  # `frappe build`: compiles the committed tree in a pinned Linux container and
  # writes a tarball of a static linux/amd64 binary and `public/`, with a
  # checksum and a CycloneDX SBOM beside it (ADR 0032).
  class ReleaseBuild
    IMAGE = "crystallang/crystal:1.22.1-alpine@sha256:" \
            "9beda8a9d4a3659c29d185cc18f3fb9b382421bb6a4a59b8f266a6fb4ccc9f16"
    # Replaces IMAGE; only a digest-pinned reference keeps the build reproducible.
    IMAGE_VARIABLE = "CARAMEL_BUILD_IMAGE"
    IMAGE_PINNED   = /\A[\w.\/-]+(?::[\w.-]+)?@sha256:[0-9a-f]{64}\z/
    PLATFORM       = "linux/amd64"
    ARTIFACT       = /\A[a-z][a-z0-9_]*-\d{8}T\d{6}Z-[0-9a-f]{7}-linux-amd64\.tar\.gz\z/
    SHARD          = /\A[a-z][a-z0-9_]*\z/
    GIT            = "/usr/bin/git"
    TAR            = "/usr/bin/tar"
    # The Alpine packages whose archives the static binary links, as the SBOM
    # names them: `openssl-libs-static` is the library `openssl`.
    LIBRARIES = %w[musl gc-static gmp-static openssl-libs-static pcre2-static zlib-static]
    # A library line of VERSIONS, such as `openssl-libs-static-3.5.9-r0`.
    LIBRARY = /\A(#{LIBRARIES.join('|')})-(\d\S*)\z/
    # Written by SCRIPT: `crystal --version`, `shards --version` and the
    # installed packages with their versions; LIBRARY picks the linked ones.
    VERSIONS = "sbom-versions.txt"
    # Runs in the container with the entry point, the shard and the artifact's
    # name as $1, $2 and $3. gmp-static gives `require "big"` the archive a
    # static link needs. Debug info stays, for Crema's backtraces.
    SCRIPT = <<-SH
      apk add --no-cache gmp-static
      shards install --frozen --without-development
      mkdir -p /work/stage/bin
      crystal build "$1" --release --static -o "/work/stage/bin/$2"
      if [ -d public ]; then cp -R public /work/stage/public; else mkdir -p /work/stage/public; fi
      tar -czf "/work/$3" -C /work/stage bin public
      { crystal --version; shards --version; apk info -v; } > "/work/#{VERSIONS}"
      SH
    DIRTY = "The working tree has uncommitted changes; commit or stash them, " \
            "then run frappe build:"
    PUBLISHED = "Publishing app/assets changed tracked files; commit them, " \
                "then run frappe build:"
    UNPINNED = "#{IMAGE_VARIABLE} must name an image by digest, such as " \
               "crystallang/crystal:1.22.1-alpine@sha256:<64 hex digits>; got "

    def initialize(@project : Project, @log : IO, @now : Time = Time.utc)
    end

    # Builds the artifact from HEAD and returns its absolute path. Its checksum
    # and SBOM sit beside it as `<artifact>.sha256` and `<artifact>.sbom.json`.
    def run : String
      root = @project.root
      prefix = repository_prefix(root)
      require_clean(root, DIRTY)
      DevFiles.new(root).publish_assets
      require_clean(root, PUBLISHED)
      docker = Process.find_executable("docker") ||
               raise Error.new("frappe build needs Docker: put docker on PATH, " \
                               "for example by starting Docker Desktop")
      image = self.class.image
      shard = shard_name(root)
      # Exactly 7 digits: `rev-parse --short=7` prints more when 7 are ambiguous.
      sha7 = git!(root, "rev-parse", "HEAD")[0, 7]
      artifact = self.class.artifact_name(shard, @now, sha7)
      state = Latte::StateSecurity.ensure_owned_directory(File.join(root, ".caramel"))
      build = File.join(state, "build")
      Dir.mkdir_p(build)
      work = File.join(build, "work-#{Random::Secure.hex(4)}")
      path = File.join(build, artifact)
      begin
        export(root, prefix, work)
        compile(docker, image, root, work, shard, artifact)
        info = File.join(work, "source/lib/.shards.info")
        sbom = self.class.sbom(shard, sha7, image, File.read(File.join(work, VERSIONS)),
          File.file?(info) ? File.read(info) : nil)
        File.rename(File.join(work, artifact), path)
      ensure
        FileUtils.rm_rf(work)
      end
      File.write("#{path}.sha256", self.class.checksum(path))
      File.write("#{path}.sbom.json", sbom)
      @log.puts "Wrote #{artifact}.sha256 and #{artifact}.sbom.json beside it"
      path
    end

    # IMAGE, or the digest-pinned image named by CARAMEL_BUILD_IMAGE.
    def self.image : String
      override = ENV[IMAGE_VARIABLE]?.presence || return IMAGE
      return override if override.matches?(IMAGE_PINNED)
      raise Error.new(UNPINNED + override.inspect)
    end

    # The artifact's SHA-256 as `sha256sum -c` reads it: the hex digest, two
    # spaces and the file's name.
    def self.checksum(path : String) : String
      "#{Digest::SHA256.new.file(path).hexfinal}  #{File.basename(path)}\n"
    end

    # A CycloneDX 1.5 bill of materials: the application at its commit, the
    # Crystal it was compiled with, each shard in *shards_info* (Shards'
    # `lib/.shards.info`) and each of LIBRARIES at the version *versions*
    # (the file SCRIPT wrote) records. The image digest is a property.
    def self.sbom(shard : String, sha7 : String, image : String, versions : String,
                  shards_info : String?) : String
      lines = versions.lines.map(&.strip)
      crystal = lines.find(&.starts_with?("Crystal ")).try(&.split(' ')[1]?) || "unknown"
      shards = lines.find(&.starts_with?("Shards ")).try(&.split(' ')[1]?) || "unknown"
      JSON.build(indent: "  ") do |json|
        json.object do
          json.field "bomFormat", "CycloneDX"
          json.field "specVersion", "1.5"
          json.field "version", 1
          json.field "metadata" do
            json.object do
              json.field "tools" do
                json.array do
                  tool(json, "crystal", crystal)
                  tool(json, "shards", shards)
                end
              end
              json.field "component" { component(json, "application", shard, sha7) }
            end
          end
          json.field "components" do
            json.array do
              component(json, "application", shard, sha7)
              component(json, "application", "crystal", crystal)
              shard_versions(shards_info).each do |name, version, commit|
                component(json, "library", name, version) do
                  properties(json, "caramel:commit", commit) if commit
                end
              end
              lines.each do |line|
                match = line.match(LIBRARY) || next
                component(json, "library", match[1].sub(/-(libs-)?static\z/, ""), match[2]) do
                  json.field "purl", "pkg:apk/alpine/#{match[1]}@#{match[2]}"
                end
              end
            end
          end
          properties(json, "caramel:build-image", image)
        end
      end + "\n"
    end

    # Each shard's name, version and, for one installed at a git commit, that
    # commit, which Shards records as `VERSION+git.commit.SHA`.
    def self.shard_versions(info : String?) : Array({String, String, String?})
      shards = info.try { |text| YAML.parse(text)["shards"]?.try(&.as_h?) }
      return [] of {String, String, String?} unless shards
      shards.compact_map do |name, entry|
        recorded = entry["version"]?.try(&.as_s?) || next
        version, _, commit = recorded.partition("+git.commit.")
        {name.as_s, version, commit.presence}
      end
    end

    private def self.tool(json : JSON::Builder, name : String, version : String) : Nil
      json.object do
        json.field "name", name
        json.field "version", version
      end
    end

    private def self.component(json : JSON::Builder, type : String, name : String,
                               version : String, &) : Nil
      json.object do
        json.field "type", type
        json.field "name", name
        json.field "version", version
        yield
      end
    end

    private def self.component(json : JSON::Builder, type : String, name : String,
                               version : String) : Nil
      component(json, type, name, version) { }
    end

    private def self.properties(json : JSON::Builder, name : String, value : String) : Nil
      json.field "properties" do
        json.array do
          json.object do
            json.field "name", name
            json.field "value", value
          end
        end
      end
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
                                 image : String,
                                 entrypoint : String,
                                 shard : String,
                                 artifact : String) : Array(String)
      arguments = ["run", "--rm", "--platform", PLATFORM, "-v", "#{work}:/work"]
      mounts.each { |host, container| arguments.push("-v", "#{host}:#{container}:ro") }
      arguments + ["-w", "/work/source", image, "sh", "-euc", SCRIPT, "sh",
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

    # Runs the build script in *image* with the user's environment, so that
    # `docker` finds its context and credentials.
    private def compile(docker : String, image : String, root : String, work : String,
                        shard : String, artifact : String) : Nil
      mounts = self.class.path_mounts(File.read(File.join(root, "shard.yml")), root)
      arguments = self.class.container_arguments(work, mounts, image, @project.entrypoint,
        shard, artifact)
      @log.puts "Building #{artifact} in #{image} for #{PLATFORM}"
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
