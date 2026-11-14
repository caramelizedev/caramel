require "digest/sha256"
require "json"
require "random/secure"
require "./build_slot"
require "./dev_files"
require "./project"
require "./toolkit"
require "./tools"

module Caramel::Frappe
  # The program a shard ships for its tool commands (ShardCommands), built from the
  # Crystal entry file its manifest names. Frappé builds it in the project, with the
  # project's toolchain and the project's copy of the framework, into the toolchain:
  # one place for each shard and version, reused while the fingerprint, the toolchain
  # and the framework version are the ones it was built from (BuildSlot). So a shard at
  # one version or commit builds once for every project, and a path dependency builds
  # again when its sources change. Nothing of the application is compiled, which may
  # not build or not yet require the shard: a generator is how a shard gets added.
  class ShardTool
    # Where the toolchain keeps the programs, each in SHARD-VERSION.
    CACHE = "shard-tools"
    MODE  = "tool"

    # The program of *shard*, whose manifest names *entry* from the shard's root, for
    # the project at *root*; *error* hears about a build.
    def initialize(@tools : Tools,
                   @root : String,
                   @shard : String,
                   @entry : String,
                   @error : IO)
    end

    # Runs the program once in the project's root with *arguments*, the command's words
    # as the manifest writes them and what follows them, on the terminal's streams, and
    # returns its exit status. It is told the project's root and who reads its output
    # (Toolkit), and nothing of the project's local environment.
    def run(arguments : Array(String), agent : Bool, color : Bool) : Int32
      values = Toolkit.environment(@root, agent, color)
      @tools.execute(binary, arguments, @root, values).exit_code? || 1
    end

    # The built program: the one the toolchain keeps, or a new build when it keeps none
    # of this fingerprint.
    def binary : String
      toolchain = @tools.toolchain.root
      directory = ShardTool.directory(toolchain, @root, @shard)
      lock = BuildLock.new(directory)
      slot = ShardTool.slot(toolchain, @root, @shard)
      begin
        lock.acquire { @error.puts("Waiting for another build of #{title}…") }
        fingerprint = ShardTool.fingerprint(@root, @shard, @entry)
        build(slot, fingerprint) unless slot.holds?(fingerprint)
      ensure
        lock.release
      end
      slot.binary
    end

    # Where *toolchain* keeps the program of *shard* at the version that the project at
    # *root* locks.
    def self.directory(toolchain : String, root : String, shard : String) : String
      version = locked(root, shard)["version"]? || "unversioned"
      File.join(toolchain, CACHE, "#{shard}-#{version.gsub(/[^A-Za-z0-9._+-]/, '-')}")
    end

    # The build *toolchain* keeps of *shard*'s program at the version that the project
    # at *root* locks.
    def self.slot(toolchain : String, root : String, shard : String) : BuildSlot
      directory = directory(toolchain, root, shard)
      BuildSlot.new(File.join(directory, "tool"), File.join(directory, "tool.json"),
        toolchain, MODE)
    end

    # What a build of *shard*'s program from *entry* is made of, apart from the
    # toolchain and the framework version that its BuildSlot records: the shard as the
    # project at *root* locks it, by source and version or commit, or for a path
    # dependency by version and the signature of its sources; and the framework's
    # sources where the framework is a path dependency too.
    def self.fingerprint(root : String, shard : String, entry : String) : String
      sources = DevFiles.path_sources(root)
      source = sources["lib/#{shard}"]?
      locked = locked(root, shard)
      locked = locked.select("version") if source
      parts = {
        shard: shard, entry: entry, locked: locked.to_a.sort!,
        source: source, framework: sources["lib/caramel"]?,
      }
      Digest::SHA256.hexdigest(parts.to_json)
    end

    # What the shard.lock of the project at *root* says of *shard*, field by field.
    private def self.locked(root : String, shard : String) : Hash(String, String)
      entry = Project.locked(root)[shard]?.try(&.as_h?) || return {} of String => String
      entry.to_h { |field, value| {field.to_s, value.to_s} }
    end

    # Builds the program into *slot*, saying so first: the build takes a while once.
    private def build(slot : BuildSlot, fingerprint : String) : Nil
      @error.puts("Building #{title}; later runs reuse the build.")
      temporary = "#{slot.binary}-building-#{Random::Secure.hex(8)}"
      begin
        compile(temporary)
        slot.install(temporary, fingerprint)
      ensure
        File.delete?(temporary)
        File.delete?(temporary + ".dwarf")
      end
    end

    # Compiles the entry file to *binary* in the project, where `lib` holds the shard
    # and the framework. A failure is the shard's, reported with what the compiler said.
    private def compile(binary : String) : Nil
      source = File.join("lib", @shard, @entry)
      crystal = File.join(@tools.framework_root, "scripts/crystal")
      compiler = IO::Memory.new
      status = Process.run(crystal, ["build", source, "-o", binary],
        chdir: @root,
        env: @tools.environment,
        clear_env: true,
        input: Process::Redirect::Close,
        output: compiler,
        error: compiler)
      return if status.success?
      raise Error.new("#{source}: #{title} does not build, so its commands cannot run. " \
                      "The fault is in the shard, not in this application; report it " \
                      "to the shard's author with the compiler's output:\n" \
                      "#{compiler.to_s.rstrip}")
    end

    private def title : String
      "the #{@shard} shard's tool program"
    end
  end
end
