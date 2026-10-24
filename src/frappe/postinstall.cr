require "yaml"
require "file_utils"
require "random/secure"
require "./project"

module Caramel::Frappe
  # Runs the postinstall script of each installed dependency that declares
  # one, as Shards would after `shards install`, and keeps the files the
  # script writes into the dependency's directory in the toolchain, keyed by
  # the dependency's name and version. The next application that installs
  # the same version copies those files instead of running the script.
  # Lexbor's downloads 14 MB of C and compiles it, about 9 s on every
  # `frappe new` and `frappe setup`.
  class Postinstall
    CACHE  = "postinstall-cache"
    MARKER = ".postinstall"

    # *execute* runs a shell command in a directory with the tools'
    # environment and raises `Error` when it fails.
    def initialize(@framework_root : String,
                   @toolchain_root : String,
                   @output : IO,
                   &@execute : String, String, Hash(String, String) -> Nil)
    end

    def run(project_root : String) : Nil
      library = File.join(project_root, "lib")
      installed(library).each do |name, version|
        directory = File.join(library, name)
        script = postinstall(directory) || next
        cache = File.join(@toolchain_root, CACHE, "#{name}-#{version}")
        if kept?(cache, script)
          @output.puts "I: Postinstall of #{name}: kept from the toolchain"
          copy_tree(cache, directory)
        else
          @output.puts "I: Postinstall of #{name}: #{script}"
          before = listing(directory)
          hooks(directory) { |env| @execute.call(script, directory, env) }
          keep(cache, directory, listing(directory), before, script)
        end
      end
    end

    # Each installed dependency's name and version, from Shards' record.
    private def installed(library : String) : Array({String, String})
      info = File.join(library, ".shards.info")
      return [] of {String, String} unless File.file?(info)
      shards = YAML.parse(File.read(info))["shards"]?.try(&.as_h?) || return [] of {String, String}
      shards.compact_map do |name, entry|
        version = entry["version"]?.try(&.as_s?) || next
        {name.as_s, version}
      end
    end

    # The dependency's postinstall script, or nil.
    private def postinstall(directory : String) : String?
      manifest = File.join(directory, "shard.yml")
      return unless File.file?(manifest)
      YAML.parse(File.read(manifest))["scripts"]?.try(&.["postinstall"]?).try(&.as_s?)
    rescue YAML::ParseException
      nil
    end

    private def kept?(cache : String, script : String) : Bool
      marker = File.join(cache, MARKER)
      File.file?(marker) && File.read(marker) == script
    end

    # Every file under *directory*, by relative path, with its size and
    # modification time.
    private def listing(directory : String) : Hash(String, {Int64, Time})
      files = {} of String => {Int64, Time}
      Dir.glob(File.join(directory, "**/*"), match: :dot_files) do |path|
        info = File.info?(path, follow_symlinks: false) || next
        next unless info.file?
        files[path.lchop(directory + "/")] = {info.size.to_i64, info.modification_time}
      end
      files
    end

    # Copies the files the script added or changed into *cache*, built
    # beside it and renamed into place; another process's cache wins a race.
    private def keep(cache : String,
                     directory : String,
                     after : Hash(String, {Int64, Time}),
                     before : Hash(String, {Int64, Time}),
                     script : String) : Nil
      written = after.keys.select { |path| before[path]? != after[path] }
      return if written.empty?
      Dir.mkdir_p(File.dirname(cache), 0o700)
      building = "#{cache}.#{Random::Secure.hex(4)}"
      Dir.mkdir(building, 0o700)
      written.each do |path|
        target = File.join(building, path)
        Dir.mkdir_p(File.dirname(target))
        File.copy(File.join(directory, path), target)
      end
      File.write(File.join(building, MARKER), script)
      begin
        File.rename(building, cache)
      rescue File::Error
        FileUtils.rm_rf(building)
      end
    end

    private def copy_tree(cache : String, directory : String) : Nil
      Dir.glob(File.join(cache, "**/*"), match: :dot_files) do |path|
        next unless File.file?(path)
        relative = path.lchop(cache + "/")
        next if relative == MARKER
        target = File.join(directory, relative)
        Dir.mkdir_p(File.dirname(target))
        File.copy(path, target)
      end
    end

    # A `crystal` on PATH that runs the managed launcher, as scripts/shards
    # gives a postinstall script.
    private def hooks(directory : String, & : Hash(String, String) -> Nil) : Nil
      hooks = File.tempname("caramel-shard-hooks", dir: ENV["TMPDIR"]? || "/private/tmp")
      Dir.mkdir(hooks, 0o700)
      shim = File.join(hooks, "crystal")
      launcher = File.join(@framework_root, "scripts/crystal").inspect
      File.write(shim, "#!/bin/sh\nexec #{launcher} \"$@\"\n")
      File.chmod(shim, 0o700)
      yield({"PATH" => "#{hooks}:#{@toolchain_root}/bin:/usr/bin:/bin:/usr/sbin:/sbin"})
    ensure
      FileUtils.rm_rf(hooks) if hooks
    end
  end
end
