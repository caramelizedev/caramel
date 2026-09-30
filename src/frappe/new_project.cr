require "file_utils"
require "yaml"
require "./project"
require "./dev_files"
require "../latte/process"

module Caramel::Frappe
  class NewProject
    # How a generated application depends on the framework (ADR 0016): its
    # shard.yml source lines and its shard.lock source line.
    record Dependency, shard : String, lock : String

    def initialize(framework_root : String)
      @framework_root = File.realpath(framework_root)
    end

    def create(name : String, directory : String, suffix : String = "caramel") : Project
      Latte::Site.validate_name(name)
      suffix = Latte::Site.normalize_suffix(suffix)
      destination = File.expand_path(directory)
      parent = File.realpath(File.dirname(destination))
      destination = File.join(parent, File.basename(destination))
      preflight_destination(destination)
      files = plan(name, suffix)
      stage = File.join(parent, ".caramel-new-#{Random::Secure.hex(8)}")
      Dir.mkdir(stage, 0o700)
      begin
        files.each do |relative, content|
          path = File.join(stage, relative)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
        end
        preflight_destination(destination)
        Dir.delete(destination) if Dir.exists?(destination)
        File.rename(stage, destination)
        # Records the public asset copies as published, so the first
        # frappe dev after an asset edit republishes instead of refusing.
        DevFiles.new(destination).publish_assets
        Project.load(destination)
      ensure
        FileUtils.rm_rf(stage) if Dir.exists?(stage)
      end
    rescue ex : ArgumentError
      raise Error.new(ex.message)
    end

    def plan(name : String, suffix : String = "caramel") : Hash(String, String)
      Latte::Site.validate_name(name)
      suffix = Latte::Site.normalize_suffix(suffix)
      shard_name = name.tr("-", "_")
      title = name.split('-').map(&.capitalize).join(' ')
      source = dependency
      substitutions = {
        "@@NAME@@"    => name,
        "@@SHARD@@"   => shard_name,
        "@@TITLE@@"   => title,
        "@@VERSION@@" => Caramel::VERSION,
        "@@SUFFIX@@"  => suffix,
        "@@CARAMEL@@" => source.shard,
      }
      result = {} of String => String
      tree(File.join(@framework_root, "templates/application")).each do |path, content|
        substitutions.each do |token, value|
          path = path.gsub(token, value)
          content = content.gsub(token, value)
        end
        result[path] = content
      end
      result["shard.lock"] = shard_lock(source)
      htmx = File.read(File.join(@framework_root, "vendor/htmx/htmx-4.0.0.min.js"))
      result["public/assets/htmx-4.0.0.min.js"] = htmx
      result["app/assets/vendor/htmx-4.0.0.min.js"] = htmx
      islands = File.read(File.join(@framework_root, "src/caramel/islands.js"))
      result["public/assets/caramel-islands.js"] = islands
      result["app/assets/vendor/caramel-islands.js"] = islands
      result["public/assets/app.css"] = result["app/assets/stylesheets/app.css"]
      result["public/assets/app.js"] = result["app/assets/javascript/app.js"]
      result
    end

    # The tagged release on GitHub; CARAMEL_REPOSITORY, a git URL, for tests
    # and forks; or, from a checkout that is not exactly its clean release
    # tag, the checkout itself.
    def dependency : Dependency
      pin = "\n    version: \"~> #{Caramel::VERSION}\""
      if repository = ENV["CARAMEL_REPOSITORY"]?
        source = "git: #{repository.to_json}"
        Dependency.new(shard: source + pin, lock: source)
      elsif released?
        release = "git: #{"#{Caramel::REPOSITORY}.git".to_json}"
        Dependency.new(shard: "github: caramelizedev/caramel" + pin, lock: release)
      else
        source = "path: #{@framework_root.to_json}"
        Dependency.new(shard: source, lock: source)
      end
    end

    private def released? : Bool
      return false unless File.exists?(File.join(@framework_root, ".git"))
      tag = git("describe", "--exact-match", "--tags", "HEAD")
      return false unless tag.success? && tag.stdout.strip == "v#{Caramel::VERSION}"
      # Untracked files, such as an app generated inside the clone, change nothing.
      status = git("status", "--porcelain", "--untracked-files=no")
      status.success? && status.stdout.empty?
    end

    private def git(*arguments : String) : Latte::ProcessResult
      command = ["/usr/bin/git", "-C", @framework_root] + arguments.to_a
      Latte::ProcessRunner.run(command, timeout: 10.seconds)
    end

    # The framework at this release, then its runtime dependencies exactly as
    # the framework locks them.
    private def shard_lock(source : Dependency) : String
      framework = YAML.parse(File.read(File.join(@framework_root, "shard.yml")))
      development_shards = framework["development_dependencies"]?
      development = development_shards.try(&.as_h.keys.map(&.as_s)) || [] of String
      locked = YAML.parse(File.read(File.join(@framework_root, "shard.lock")))["shards"].as_h
      String.build do |io|
        io << "version: 2.0\nshards:\n  caramel:\n    " << source.lock
        io << "\n    version: " << Caramel::VERSION << '\n'
        locked.each do |name, entry|
          next if development.includes?(name.as_s)
          io << "\n  " << name.as_s << ":\n"
          entry.as_h.each { |key, value| io << "    " << key.as_s << ": " << value.as_s << '\n' }
        end
      end
    end

    private def preflight_destination(path : String) : Nil
      if info = File.info?(path, follow_symlinks: false)
        unless info.directory? && Dir.children(path).empty?
          raise Error.new("Project destination must be an empty directory; " \
                          "existing files were preserved")
        end
      end
    end

    private def tree(root : String, prefix : String = "") : Hash(String, String)
      info = File.info(root, follow_symlinks: false)
      raise Error.new("Framework template directory must be regular") unless info.directory?
      result = {} of String => String
      Dir.children(root).sort.each do |name|
        path = File.join(root, name)
        relative = prefix.empty? ? name : File.join(prefix, name)
        info = File.info(path, follow_symlinks: false)
        raise Error.new("Framework template must not contain symlinks") if info.symlink?
        if info.directory?
          result.merge!(tree(path, relative))
        elsif info.file?
          result[relative] = File.read(path)
        else
          raise Error.new("Unexpected file in framework template")
        end
      end
      result
    end
  end
end
