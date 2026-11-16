require "file_utils"
require "yaml"
require "./error"
require "../latte/process"

module Caramel::Frappe
  # The shards a release publishes for applications to install. Shards copies a
  # repository's whole tagged tree into an application's lib/, so each shard that
  # `published.yml` declares is assembled, from one commit of this repository or from its
  # working tree, into a git repository of its own: one commit, on the branch `main`,
  # tagged with the release's version.
  #
  # A published commit has no parent, a fixed author, its source commit's date and a
  # message that states only the shard and its version. Git runs there with a fixed
  # environment and no configuration of this machine, and files are stored as their
  # bytes. So the commit's id follows from the source commit alone: whoever has that
  # commit computes the id offline, and nothing records it.
  #
  # The author, the message and the rest of what an id follows from are fixed here. A
  # release computes its ids with the code of its own tag, in `frappe new` and in
  # scripts/release, so a change here changes the ids of later releases only; assemble
  # an earlier tag with that tag's own scripts/assemble-shards.
  module Published
    # Where the repository declares its published shards, relative to its root.
    DECLARATION = "published.yml"
    # A shard's own manifest, relative to its tree's root.
    MANIFEST = "shard.yml"
    README   = "README.md"
    # The branch of a published repository that holds its newest release.
    BRANCH = "main"
    # Who a published commit is by. Changing either changes the id of every commit
    # assembled afterwards. The address is provisional: settle it before the first
    # release is published, since it is part of every id from then on.
    AUTHOR = "Caramel"
    EMAIL  = "releases@caramelize.dev"

    GIT = "/usr/bin/git"
    # Above the bytes of any tree a release publishes.
    OUTPUT_LIMIT = 256 * 1024 * 1024

    # Git's whole environment in a published repository: no configuration, identity or
    # GIT_* variable of this machine reaches a published commit.
    ENVIRONMENT = {
      "GIT_CONFIG_GLOBAL"   => "/dev/null",
      "GIT_CONFIG_SYSTEM"   => "/dev/null",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_AUTHOR_NAME"     => AUTHOR,
      "GIT_AUTHOR_EMAIL"    => EMAIL,
      "GIT_COMMITTER_NAME"  => AUTHOR,
      "GIT_COMMITTER_EMAIL" => EMAIL,
    } of String => String?

    # An assembled shard: the GitHub repository it is published to, the release's
    # version, its published commit and the local repository that holds it.
    record Shard,
      name : String,
      repository : String,
      version : String,
      commit : String,
      directory : String do
      def tag : String
        "v#{version}"
      end

      # Where Shards fetches it from, as a lock records a `github:` dependency.
      def url : String
        "https://github.com/#{repository}.git"
      end

      # The version a lock records to pin the published commit, in Shards' form.
      def pin : String
        "#{version}+git.commit.#{commit}"
      end

      # The command that publishes it: the tag, and the branch moved to it. The commit
      # has no parent, so the branch is forced; the tag is not, and a tag that exists
      # there at another commit refuses the push.
      def push : String
        "git -C #{Process.quote(directory)} push #{url} +#{BRANCH} #{tag}"
      end
    end

    # A file of a published tree: where the source holds it, its bytes and its mode.
    record Entry, origin : String, bytes : Bytes, executable : Bool

    # Git in one directory, with this process's environment or with *environment* alone.
    private struct Git
      def initialize(@directory : String, @environment : Hash(String, String?)? = nil)
      end

      def run(*arguments : String, input : String? = nil) : String
        result = Latte::ProcessRunner.run([GIT, "-C", @directory] + arguments.to_a,
          input: input,
          env: @environment,
          clear_env: !@environment.nil?,
          timeout: 120.seconds,
          output_limit: OUTPUT_LIMIT)
        return result.stdout if result.success?
        failure = result.timed_out? ? "took too long" : result.stderr.strip
        raise Error.new("git #{arguments.first} failed in #{@directory}: #{failure}")
      end
    end

    # What a release is assembled from: the files it holds, and the commit that dates
    # its published commits.
    private abstract class Source
      getter repository : String

      def initialize(@repository : String)
        @git = Git.new(@repository)
      end

      # How a message names it.
      abstract def label : String

      # The commit whose date its published commits take.
      abstract def dated : String

      # The files it holds, relative to the repository's root.
      abstract def paths : Array(String)

      # Each of *paths* as an entry of a published tree.
      abstract def read(paths : Array(String)) : Hash(String, Entry)

      # The committer date of `dated` in UTC, as git reads a date.
      def date : String
        "@#{@git.run("show", "--no-patch", "--format=%ct", dated).strip} +0000"
      end

      def text(path : String) : String
        raise Error.new("#{label} holds no #{path}") unless paths.includes?(path)
        String.new(read([path])[path].bytes)
      end

      private def irregular(path : String) : Error
        Error.new("#{path} in #{label} is not a regular file; " \
                  "a published tree holds only regular files")
      end
    end

    # A commit: its files are the blobs of its tree, whatever the checkout holds.
    private class Commit < Source
      REGULAR = {"100644", "100755"}

      @id : String

      def initialize(repository : String, revision : String)
        super(repository)
        @id = Commit.resolve(repository, revision)
        @blobs = {} of String => {String, String}
        listing = @git.run("ls-tree", "-r", "-z", "--full-tree", @id)
        listing.split('\0', remove_empty: true).each do |line|
          description, _, path = line.partition('\t')
          mode, _, id = description.split(' ')
          @blobs[path] = {mode, id}
        end
      end

      def label : String
        "commit #{@id[0, 12]} of #{repository}"
      end

      def dated : String
        @id
      end

      def paths : Array(String)
        @blobs.keys
      end

      def read(paths : Array(String)) : Hash(String, Entry)
        paths.each { |path| raise irregular(path) unless REGULAR.includes?(@blobs[path][0]) }
        ids = paths.map { |path| @blobs[path][1] }
        blobs = @git.run("cat-file", "--batch", input: ids.join('\n') + "\n").to_slice
        offset = 0
        paths.to_h do |path|
          mode, id = @blobs[path]
          bytes, offset = blob(blobs, offset, id)
          {path, Entry.new(path, bytes, mode == "100755")}
        end
      rescue IndexError
        raise Error.new("git cat-file returned less than the files of #{label}")
      end

      # The blob *id* that `git cat-file --batch` wrote at *offset*, and the offset of
      # the next one: a line `<id> blob <size>`, the bytes and a line feed.
      private def blob(blobs : Bytes, offset : Int32, id : String) : {Bytes, Int32}
        newline = blobs.index('\n'.ord.to_u8, offset) || raise IndexError.new
        header = String.new(blobs[offset...newline]).split(' ')
        unless header.size == 3 && header[0] == id && header[1] == "blob"
          raise Error.new("#{label} holds no file #{id}")
        end
        size = header[2].to_i
        {blobs[newline + 1, size], newline + size + 2}
      end

      protected def self.resolve(repository : String, revision : String) : String
        verify = [GIT, "-C", repository, "rev-parse", "--verify", "--quiet",
                  "#{revision}^{commit}"]
        result = Latte::ProcessRunner.run(verify, timeout: 30.seconds)
        id = result.stdout.strip
        return id if result.success? && id.matches?(/\A[0-9a-f]{40,64}\z/)
        raise Error.new("#{repository} has no commit #{revision}")
      end
    end

    # The checkout as it is: every file git tracks or would add, read from disk. Its
    # published commits take the date of HEAD, so a clean checkout assembles what its
    # commit does.
    private class WorkingTree < Source
      getter paths : Array(String)

      def initialize(repository : String)
        super
        listed = @git.run("ls-files", "-z", "--cached", "--others", "--exclude-standard")
        @paths = listed.split('\0', remove_empty: true).select do |path|
          File.info?(File.join(repository, path), follow_symlinks: false)
        end
      end

      def label : String
        "the working tree of #{repository}"
      end

      def dated : String
        "HEAD"
      end

      def read(paths : Array(String)) : Hash(String, Entry)
        paths.to_h do |path|
          file = File.join(repository, path)
          info = File.info(file, follow_symlinks: false)
          raise irregular(path) unless info.file?
          executable = info.permissions.owner_execute?
          {path, Entry.new(path, File.open(file, &.getb_to_end), executable)}
        end
      end
    end

    # One shard of the declaration: where it is published, and what its tree holds.
    private struct Selection
      include YAML::Serializable
      include YAML::Serializable::Strict

      getter repository : String
      getter root : String?
      getter paths : Array(String)?
      getter readme : String?

      # The tree of the shard *name*, by path, as *source* holds it.
      def tree(name : String, source : Source) : Hash(String, Entry)
        origins = origins(name, source)
        read = source.read(origins.values)
        tree = origins.transform_values { |origin| read[origin] }
        if text = readme
          if tree.has_key?(README)
            raise Error.new("#{DECLARATION}: #{name} states a readme and selects " \
                            "#{tree[README].origin}; keep one")
          end
          tree[README] = Entry.new(DECLARATION, text.to_slice, false)
        end
        tree
      end

      # Each path of the tree with the path *source* holds it at.
      private def origins(name : String, source : Source) : Hash(String, String)
        directory, selected = root, paths
        if directory && selected.nil?
          prefix = "#{directory.rchop('/')}/"
          found = held(name, source, directory)
          found.to_h { |path| {path.lchop(prefix), path} }
        elsif selected && directory.nil?
          selected.flat_map { |path| held(name, source, path) }.to_h { |path| {path, path} }
        else
          raise Error.new("#{DECLARATION}: #{name} states either paths or root, not both")
        end
      end

      # The files of *source* that *selected* names: the file itself, or every file
      # under the directory.
      private def held(name : String, source : Source, selected : String) : Array(String)
        file = selected.rchop('/')
        found = source.paths.select { |path| path == file || path.starts_with?("#{file}/") }
        return found unless found.empty?
        raise Error.new("#{DECLARATION}: #{name} selects #{selected}, " \
                        "which #{source.label} does not hold")
      end
    end

    # Assembles every declared shard of *repository* into a new git repository
    # `<directory>/<name>`, and returns them by name: from *commit*, any revision of
    # *repository*, or from its working tree. Each repository's checkout holds exactly
    # the shard's tree, and its tag `v<version>` and branch `main` name its one commit.
    def self.assemble(repository : String,
                      directory : String,
                      commit : String? = nil) : Hash(String, Shard)
      source = commit ? Commit.new(repository, commit) : WorkingTree.new(repository)
      selections = declaration(source)
      trees = selections.to_h { |name, selection| {name, selection.tree(name, source)} }
      version = version(selections, trees)
      date = source.date
      targets = selections.to_h { |name, _| {name, File.join(directory, name)} }
      taken = targets.values.find { |target| File.info?(target, follow_symlinks: false) }
      raise Error.new("#{taken} exists; assemble into a directory without it") if taken
      selections.to_h do |name, selection|
        id = publish(targets[name], trees[name], "#{name} #{version}", "v#{version}", date)
        {name, Shard.new(name, selection.repository, version, id, targets[name])}
      end
    end

    # Yields the shards of *repository*, assembled as `assemble` does in a directory
    # that lasts as long as the block: for their commit ids alone.
    def self.assembled(repository : String,
                       commit : String? = nil,
                       & : Hash(String, Shard) -> T) : T forall T
      directory = File.tempname("caramel-published-", dir: "/private/tmp")
      Dir.mkdir(directory, 0o700)
      begin
        yield assemble(repository, directory, commit)
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    private def self.declaration(source : Source) : Hash(String, Selection)
      Hash(String, Selection).from_yaml(source.text(DECLARATION))
    rescue ex : YAML::ParseException
      raise Error.new("#{DECLARATION}: #{ex.message}")
    end

    # The version every shard's manifest states. Each manifest names its shard, and
    # takes any other shard of the release from the repository it is published to, at
    # exactly that version.
    private def self.version(selections : Hash(String, Selection),
                             trees : Hash(String, Hash(String, Entry))) : String
      version = nil
      trees.each do |name, tree|
        entry = tree[MANIFEST]?
        raise Error.new("#{DECLARATION}: #{name} selects no #{MANIFEST}") unless entry
        stated = manifest(entry)
        unless stated["name"]?.try(&.as_s?) == name
          raise Error.new("#{entry.origin}: it is not the manifest of a shard named #{name}")
        end
        own = stated["version"]?.try(&.as_s?)
        version ||= own
        unless own && own == version
          raise Error.new("#{entry.origin}: states version #{own.inspect}, and the " \
                          "release is #{version}; a release's shards share its version")
        end
      end
      release = version || raise Error.new("#{DECLARATION} declares no shard")
      trees.each_value { |tree| check_dependencies(tree[MANIFEST], selections, release) }
      release
    end

    private def self.manifest(entry : Entry) : YAML::Any
      YAML.parse(String.new(entry.bytes))
    rescue ex : YAML::ParseException
      raise Error.new("#{entry.origin}: #{ex.message}")
    end

    private def self.check_dependencies(entry : Entry,
                                        selections : Hash(String, Selection),
                                        version : String) : Nil
      dependencies = manifest(entry)["dependencies"]?.try(&.as_h?) || return
      dependencies.each do |key, dependency|
        name = key.as_s? || next
        published = selections[name]? || next
        source = dependency["github"]?.try(&.as_s?)
        unless source == published.repository
          raise Error.new("#{entry.origin}: takes #{name} from #{source.inspect}, and " \
                          "#{DECLARATION} publishes it to #{published.repository}; " \
                          "state github: #{published.repository} in both")
        end
        asked = dependency["version"]?.try(&.as_s?)
        next if asked == version
        raise Error.new("#{entry.origin}: asks for #{name} #{asked.inspect}, and the " \
                        "release is #{version}; its shards depend on each other at " \
                        "exactly its version")
      end
    end

    # Writes *tree* into the new repository *directory* and commits it, and returns the
    # commit's id. Each file is stored as its bytes, without git's conversions, under
    # the mode the tree states.
    private def self.publish(directory : String,
                             tree : Hash(String, Entry),
                             message : String,
                             tag : String,
                             date : String) : String
      FileUtils.mkdir_p(directory)
      dated = {"GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date} of String => String?
      git = Git.new(directory, ENVIRONMENT.merge(dated))
      git.run("init", "--quiet", "--template=", "--initial-branch=#{BRANCH}")
      paths = tree.keys.sort!
      paths.each { |path| write(File.join(directory, path), path, tree[path]) }
      stored = git.run("hash-object", "-w", "--no-filters", "--stdin-paths",
        input: paths.join('\n') + "\n")
      index = String.build do |io|
        paths.zip(stored.lines) do |path, id|
          io << (tree[path].executable ? "100755 " : "100644 ") << id << '\t' << path << '\0'
        end
      end
      git.run("update-index", "--add", "-z", "--index-info", input: index)
      id = git.run("commit-tree", git.run("write-tree").strip, "-m", message).strip
      git.run("update-ref", "refs/heads/#{BRANCH}", id)
      git.run("tag", tag, id)
      id
    end

    private def self.write(file : String, path : String, entry : Entry) : Nil
      if path.includes?('\n')
        raise Error.new("#{path.inspect} has a line break in its name; rename it")
      end
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, entry.bytes)
      File.chmod(file, entry.executable ? 0o755 : 0o644)
    end
  end
end
