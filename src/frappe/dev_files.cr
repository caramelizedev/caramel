require "digest/sha256"
require "file_utils"
require "./project"

module Caramel::Frappe
  class DevFiles
    record Snapshot, source : String, assets : String

    def initialize(@root : String)
    end

    def snapshot : Snapshot
      source = {} of String => String
      %w(src config db app vendor/caramel/src).each do |directory|
        tree(directory).each do |path, hash|
          next if path.starts_with?("app/assets/")
          source[path] = hash
        end
      end
      %w(shard.yml shard.lock .caramel-version .env).each do |path|
        source[path] = digest(File.join(@root, path)) if File.file?(File.join(@root, path))
      end
      Snapshot.new(signature(source), signature(tree("app/assets").merge(tree("public"))))
    end

    def publish_assets : Nil
      state = Latte::StateSecurity.ensure_owned_directory(File.join(@root, ".caramel"))
      manifest_path = File.join(state, "assets.json")
      validate_path(manifest_path)
      previous = File.exists?(manifest_path) ? Hash(String, String).from_json(File.read(manifest_path)) : {} of String => String
      desired = {} of String => String
      sources = {} of String => String
      tree("app/assets").each do |relative, hash|
        parts = relative.split('/')[2..]
        parts.shift if %w(stylesheets javascript vendor).includes?(parts.first?)
        path = "public/assets/" + parts.join('/')
        raise Error.new("Asset output conflict: #{path}") if desired.has_key?(path)
        desired[path] = hash
        sources[path] = relative
      end
      (previous.keys | desired.keys).each do |relative|
        unless relative.starts_with?("public/assets/") && relative.split('/').none? { |part| part.empty? || part.starts_with?('.') }
          raise Error.new("Invalid asset manifest")
        end
        path = File.join(@root, relative)
        validate_path(path)
        if File.exists?(path)
          actual = digest(path)
          unless actual == previous[relative]? || actual == desired[relative]?
            raise Error.new("Asset output conflict: #{relative}; edit app/assets or preserve your public edit before retrying")
          end
        end
      end
      desired.each do |relative, hash|
        path = File.join(@root, relative)
        next if File.file?(path) && digest(path) == hash
        FileUtils.mkdir_p(File.dirname(path))
        temporary = File.tempfile("asset-", dir: state)
        begin
          File.open(File.join(@root, sources[relative])) { |source| IO.copy(source, temporary) }
          temporary.flush
          temporary.chmod(0o644)
          temporary.close
          File.rename(temporary.path, path)
        ensure
          temporary.close
          File.delete?(temporary.path)
        end
      end
      (previous.keys - desired.keys).each { |relative| File.delete?(File.join(@root, relative)) }
      temporary = File.tempfile("assets-", dir: state)
      begin
        temporary << desired.to_json
        temporary.close
        File.rename(temporary.path, manifest_path)
      ensure
        temporary.close
        File.delete?(temporary.path)
      end
    end

    private def tree(relative : String) : Hash(String, String)
      path = File.join(@root, relative)
      result = {} of String => String
      return result unless File.info?(path, follow_symlinks: false)
      validate_path(path)
      Dir.children(path).sort.each do |name|
        next if name.starts_with?('.')
        child = File.join(path, name)
        validate_path(child)
        if File.directory?(child)
          result.merge!(tree(File.join(relative, name)))
        elsif File.file?(child)
          result[File.join(relative, name)] = digest(child)
        end
      end
      result
    end

    private def digest(path : String) : String
      validate_path(path)
      Digest::SHA256.hexdigest(File.read(path))
    end

    private def signature(files : Hash(String, String)) : String
      Digest::SHA256.hexdigest(files.to_a.sort_by(&.[0]).to_json)
    end

    private def validate_path(path : String) : Nil
      current = @root
      Path[path].relative_to(@root).parts.each do |part|
        current = File.join(current, part)
        if info = File.info?(current, follow_symlinks: false)
          raise Error.new("Development files must not follow symlinks: #{current}") if info.symlink?
        end
      end
    end
  end
end
