require "file_utils"
require "digest/sha256"
require "./project"

module Caramel::Frappe
  class NewProject
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
      substitutions = {"@@NAME@@" => name, "@@SHARD@@" => shard_name, "@@TITLE@@" => title, "@@VERSION@@" => Caramel::VERSION, "@@SUFFIX@@" => suffix}
      files = tree(File.join(@framework_root, "templates/application"))
      result = {} of String => String
      files.each do |path, content|
        substitutions.each do |token, value|
          path = path.gsub(token, value)
          content = content.gsub(token, value)
        end
        result[path] = content
      end
      framework = tree(File.join(@framework_root, "src/caramel"), "src/caramel")
      framework["src/caramel.cr"] = File.read(File.join(@framework_root, "src/caramel.cr"))
      %w(shard.yml shard.lock LICENSE THIRD_PARTY_NOTICES.md).each do |file|
        framework[file] = File.read(File.join(@framework_root, file))
      end
      manifest = {version: Caramel::VERSION, files: framework.transform_values { |content| Digest::SHA256.hexdigest(content) }}.to_json
      framework.each { |path, content| result["vendor/caramel/#{path}"] = content }
      result["vendor/caramel/snapshot.json"] = manifest + "\n"
      result["public/assets/htmx-4.0.0.min.js"] = File.read(File.join(@framework_root, "vendor/htmx/htmx-4.0.0.min.js"))
      result["app/assets/vendor/htmx-4.0.0.min.js"] = result["public/assets/htmx-4.0.0.min.js"]
      result["public/assets/app.css"] = result["app/assets/stylesheets/app.css"]
      result["public/assets/app.js"] = result["app/assets/javascript/app.js"]
      result
    end

    def verify_snapshot(project : Project) : Nil
      root = File.join(project.root, "vendor/caramel")
      manifest = JSON.parse(File.read(File.join(root, "snapshot.json")))
      raise Error.new("Framework snapshot version differs") unless manifest["version"].as_s == Caramel::VERSION
      files = manifest["files"].as_h
      actual = tree(root)
      actual.delete("snapshot.json")
      raise Error.new("Framework snapshot file inventory differs") unless actual.keys.sort == files.keys.sort
      files.each do |path, expected|
        raise Error.new("Framework snapshot changed: #{path}") unless Digest::SHA256.hexdigest(actual[path]) == expected.as_s
      end
    rescue JSON::ParseException | KeyError | TypeCastError | File::Error
      raise Error.new("Framework snapshot is missing or invalid; preserve the project's locked vendor/caramel directory")
    end

    private def preflight_destination(path : String) : Nil
      if info = File.info?(path, follow_symlinks: false)
        unless info.directory? && !info.symlink? && Dir.children(path).empty?
          raise Error.new("Project destination must be an empty directory; existing files were preserved")
        end
      end
    end

    private def tree(root : String, prefix : String = "") : Hash(String, String)
      info = File.info(root, follow_symlinks: false)
      raise Error.new("Framework snapshot/template directory must be regular") unless info.directory? && !info.symlink?
      result = {} of String => String
      Dir.children(root).sort.each do |name|
        path = File.join(root, name)
        relative = prefix.empty? ? name : File.join(prefix, name)
        info = File.info(path, follow_symlinks: false)
        raise Error.new("Framework snapshot/template must not contain symlinks") if info.symlink?
        if info.directory?
          result.merge!(tree(path, relative))
        elsif info.file?
          result[relative] = File.read(path)
        else
          raise Error.new("Unexpected file in framework snapshot/template")
        end
      end
      result
    end
  end
end
