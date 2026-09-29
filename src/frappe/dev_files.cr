require "digest/sha256"
require "file_utils"
require "./project"

module Caramel::Frappe
  class DevFiles
    record Snapshot, source : String, assets : String
    SOURCE_TREES = %w[src config db app]
    SOURCE_FILES = %w[shard.yml shard.lock .env]
    # Every path whose change can alter a snapshot (app/assets is inside app).
    WATCHED = SOURCE_TREES + SOURCE_FILES + %w[public]

    def initialize(@root : String)
    end

    def snapshot : Snapshot
      source = {} of String => String
      SOURCE_TREES.each do |directory|
        tree(directory).each do |path, hash|
          next if path.starts_with?("app/assets/")
          source[path] = hash
        end
      end
      SOURCE_FILES.each do |path|
        source[path] = digest(File.join(@root, path)) if File.file?(File.join(@root, path))
      end
      framework_source.try { |signature| source["lib/caramel"] = signature }
      Snapshot.new(signature(source), signature(tree("app/assets").merge(tree("public"))))
    end

    # A path dependency (lib/caramel, a symlink Shards made to a checkout)
    # builds against that checkout's working tree, so its source is part of
    # every build. It is hashed but not watched: after editing it, save any
    # application file or restart frappe dev. A release changes only with
    # shard.lock.
    private def framework_source : String?
      link = File.join(@root, "lib/caramel")
      return unless File.symlink?(link)
      source = File.join(File.realpath(link), "src")
      return unless Dir.exists?(source)
      files = Dir.glob(File.join(source, "**", "*")).select { |path| File.file?(path) }
      signature(files.to_h { |path| {path, Digest::SHA256.hexdigest(File.read(path))} })
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
        parts.shift if %w[stylesheets javascript vendor].includes?(parts.first?)
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
          ours = actual == previous[relative]? || actual == desired[relative]?
          conflict(relative, sources[relative]?) unless ours
        end
      end
      published = desired.dup
      desired.each do |relative, hash|
        path = File.join(@root, relative)
        next if File.file?(path) && digest(path) == hash
        published[relative] = copy_asset(state, File.join(@root, sources[relative]), path)
      end
      (previous.keys - desired.keys).each { |relative| File.delete?(File.join(@root, relative)) }
      temporary = File.tempfile("assets-", dir: state)
      begin
        temporary << published.to_json
        temporary.close
        File.rename(temporary.path, manifest_path)
      ensure
        temporary.close
        File.delete?(temporary.path)
      end
    end

    # A public file Frappé did not write: keep it and name the way forward.
    private def conflict(relative : String, source : String?) : NoReturn
      remedy = if source
                 "delete #{relative} to republish it from #{source}, " \
                 "or copy your public edit into #{source} first"
               else
                 "edit app/assets or preserve your public edit before retrying"
               end
      raise Error.new("Asset output conflict: #{relative} differs from what Frappé " \
                      "last published; #{remedy}")
    end

    # Copies one source asset into place and returns the digest of the bytes
    # copied, which an editor may have replaced since the tree was hashed.
    private def copy_asset(state : String, source : String, path : String) : String
      validate_path(source)
      content = File.read(source)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = File.tempfile("asset-", dir: state)
      begin
        temporary.write(content.to_slice)
        temporary.flush
        temporary.chmod(0o644)
        temporary.close
        File.rename(temporary.path, path)
      ensure
        temporary.close
        File.delete?(temporary.path)
      end
      Digest::SHA256.hexdigest(content)
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
