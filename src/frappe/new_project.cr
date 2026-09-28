require "file_utils"
require "yaml"
require "./project"
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
      substitutions = {"@@NAME@@" => name, "@@SHARD@@" => shard_name, "@@TITLE@@" => title, "@@VERSION@@" => Caramel::VERSION, "@@SUFFIX@@" => suffix, "@@CARAMEL@@" => source.shard}
      result = {} of String => String
      tree(File.join(@framework_root, "templates/application")).each do |path, content|
        substitutions.each do |token, value|
          path = path.gsub(token, value)
          content = content.gsub(token, value)
        end
        result[path] = content
      end
      result["shard.lock"] = shard_lock(source)
      result["public/assets/htmx-4.0.0.min.js"] = File.read(File.join(@framework_root, "vendor/htmx/htmx-4.0.0.min.js"))
      result["app/assets/vendor/htmx-4.0.0.min.js"] = result["public/assets/htmx-4.0.0.min.js"]
      result["public/assets/caramel-islands.js"] = File.read(File.join(@framework_root, "src/caramel/islands.js"))
      result["app/assets/vendor/caramel-islands.js"] = result["public/assets/caramel-islands.js"]
      result["public/assets/app.css"] = result["app/assets/stylesheets/app.css"]
      result["public/assets/app.js"] = result["app/assets/javascript/app.js"]
      result
    end

    # The tagged release on GitHub; CARAMEL_REPOSITORY, a git URL, for tests
    # and forks; or, from a checkout that is not exactly its clean release
    # tag, the checkout itself.
    def dependency : Dependency
      if repository = ENV["CARAMEL_REPOSITORY"]?
        Dependency.new("git: #{repository.to_json}\n    version: \"~> #{Caramel::VERSION}\"", "git: #{repository.to_json}")
      elsif released?
        Dependency.new("github: caramelizedev/caramel\n    version: \"~> #{Caramel::VERSION}\"", "git: #{"#{Caramel::REPOSITORY}.git".to_json}")
      else
        Dependency.new("path: #{@framework_root.to_json}", "path: #{@framework_root.to_json}")
      end
    end

    private def released? : Bool
      return false unless File.exists?(File.join(@framework_root, ".git"))
      tag = Latte::ProcessRunner.run(["/usr/bin/git", "-C", @framework_root, "describe", "--exact-match", "--tags", "HEAD"], timeout: 10.seconds)
      return false unless tag.success? && tag.stdout.strip == "v#{Caramel::VERSION}"
      status = Latte::ProcessRunner.run(["/usr/bin/git", "-C", @framework_root, "status", "--porcelain"], timeout: 10.seconds)
      status.success? && status.stdout.empty?
    end

    # The framework at this release, then its runtime dependencies exactly as
    # the framework locks them.
    private def shard_lock(source : Dependency) : String
      framework = YAML.parse(File.read(File.join(@framework_root, "shard.yml")))
      development = framework["development_dependencies"]?.try(&.as_h.keys.map(&.as_s)) || [] of String
      locked = YAML.parse(File.read(File.join(@framework_root, "shard.lock")))["shards"].as_h
      String.build do |io|
        io << "version: 2.0\nshards:\n  caramel:\n    " << source.lock << "\n    version: " << Caramel::VERSION << '\n'
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
          raise Error.new("Project destination must be an empty directory; existing files were preserved")
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
