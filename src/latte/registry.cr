require "json"
require "random/secure"
require "./paths"
require "./site"

module Caramel
  module Latte
    class Registry
      VERSION = 1

      class Error < ArgumentError
      end

      getter paths : Paths
      getter registry_file : String
      getter lock_file : String

      def initialize(@paths : Paths)
        @registry_file = File.join(@paths.root, "registry.json")
        @lock_file = File.join(@paths.root, "registry.json.lock")
        ensure_lock_file
      end

      def initialize(root : String? = nil)
        @paths = Paths.new(root)
        @registry_file = File.join(@paths.root, "registry.json")
        @lock_file = File.join(@paths.root, "registry.json.lock")
        ensure_lock_file
      end

      def register(name : String, directory : String, suffix : String = Site::DEFAULT_SUFFIX) : Site
        candidate = Site.new(name, directory, suffix)
        with_exclusive_lock do
          sites = read_unlocked
          if existing = sites.find { |site| site.name == candidate.name }
            if existing.directory == candidate.directory && existing.suffix == candidate.suffix
              next existing
            end
            raise Error.new("site name is already registered")
          end
          if existing = sites.find { |site| site.directory == candidate.directory }
            raise Error.new("project directory is already registered")
          end
          if existing = sites.find { |site| site.id == candidate.id }
            raise Error.new("site id collides with an existing site")
          end
          write_unlocked(sites + [candidate])
          candidate
        end
      end

      def find(id_or_name : String) : Site?
        with_shared_lock do
          read_unlocked.find { |site| site.id == id_or_name || site.name == id_or_name }
        end
      end

      def list : Array(Site)
        with_shared_lock do
          read_unlocked.sort_by(&.name)
        end
      end

      def unregister(id_or_name : String) : Site?
        with_exclusive_lock do
          sites = read_unlocked
          index = sites.index { |site| site.id == id_or_name || site.name == id_or_name }
          next nil unless index
          removed = sites.delete_at(index)
          write_unlocked(sites)
          removed
        end
      end

      # Validates an upstream without requiring it to be persisted. This is
      # useful to proxy startup, where a registered app may not have started
      # its socket yet.
      def validate_upstream(id_or_name : String, socket : String) : String
        site = find(id_or_name)
        raise Error.new("site is not registered") unless site
        validate_upstream_path(site, socket, require_existing: true)
      end

      def set_upstream(id_or_name : String, socket : String) : Site
        with_exclusive_lock do
          sites = read_unlocked
          index = sites.index { |site| site.id == id_or_name || site.name == id_or_name }
          raise Error.new("site is not registered") unless index
          site = sites[index]
          validated_socket = validate_upstream_path(site, socket, require_existing: true)
          updated = site.with_upstream(validated_socket)
          sites[index] = updated
          write_unlocked(sites)
          updated
        end
      end

      def clear_upstream(id_or_name : String) : Site?
        with_exclusive_lock do
          sites = read_unlocked
          index = sites.index { |site| site.id == id_or_name || site.name == id_or_name }
          next nil unless index
          updated = sites[index].without_upstream
          sites[index] = updated
          write_unlocked(sites)
          updated
        end
      end

      private def ensure_lock_file : Nil
        if info = File.info?(@lock_file, follow_symlinks: false)
          raise Error.new("registry lock path contains a symlink") if info.symlink?
          raise Error.new("registry lock path is not a file") unless info.file?
          unless info.owner_id.to_i64? == StateSecurity.current_uid
            raise Error.new("registry lock path has foreign ownership")
          end
          File.chmod(@lock_file, StateSecurity::FILE_MODE) if info.permissions.value != StateSecurity::FILE_MODE
        else
          File.open(@lock_file, "a", StateSecurity::FILE_MODE) { }
          File.chmod(@lock_file, StateSecurity::FILE_MODE)
        end
        info = File.info?(@lock_file, follow_symlinks: false)
        raise Error.new("registry lock path is unavailable") unless info
        raise Error.new("registry lock path contains a symlink") if info.symlink?
        raise Error.new("registry lock path is not private") unless info.permissions.value == StateSecurity::FILE_MODE
      rescue ex : File::Error
        raise Error.new("unable to create registry lock")
      end

      private def with_shared_lock(&)
        with_lock(shared: true) { yield }
      end

      private def with_exclusive_lock(&)
        with_lock(shared: false) { yield }
      end

      private def with_lock(shared : Bool, &)
        ensure_lock_file
        File.open(@lock_file, "r+") do |lock|
          if shared
            lock.flock_shared { yield }
          else
            lock.flock_exclusive { yield }
          end
        end
      end

      private def read_unlocked : Array(Site)
        return [] of Site unless File.info?(@registry_file, follow_symlinks: false)

        info = File.info?(@registry_file, follow_symlinks: false)
        raise Error.new("registry file contains a symlink") unless info
        raise Error.new("registry file contains a symlink") if info.symlink?
        raise Error.new("registry file is not regular") unless info.file?
        unless info.owner_id.to_i64? == StateSecurity.current_uid
          raise Error.new("registry file has foreign ownership")
        end
        unless info.permissions.value == StateSecurity::FILE_MODE
          raise Error.new("registry file must be mode 0600")
        end

        begin
          parse_unlocked(File.read(@registry_file))
        rescue ex : Error
          raise ex
        rescue
          raise Error.new("registry file is corrupt")
        end
      end

      private def parse_unlocked(document : String) : Array(Site)
        parsed = JSON.parse(document)
        object = parsed.as_h
        reject_unknown_keys(object, ["version", "sites"])
        version = object["version"]?.try(&.as_i)
        raise Error.new("unsupported registry version") unless version == VERSION
        rows = object["sites"]?.try(&.as_a)
        raise Error.new("registry sites must be an array") unless rows

        sites = [] of Site
        rows.each do |row|
          site_object = row.as_h
          reject_unknown_keys(site_object, ["id", "name", "directory", "suffix", "upstream"])
          id = site_object["id"]?.try(&.as_s)
          name = site_object["name"]?.try(&.as_s)
          directory = site_object["directory"]?.try(&.as_s)
          suffix = site_object["suffix"]?.try(&.as_s)
          unless id && name && directory && suffix
            raise Error.new("registry site metadata is incomplete")
          end
          upstream = site_object["upstream"]?.try do |value|
            value.raw.nil? ? nil : value.as_s
          end
          site = Site.from_stored(id, name, directory, suffix, upstream)
          if sites.any? { |existing| existing.id == site.id || existing.name == site.name || existing.directory == site.directory }
            raise Error.new("registry contains duplicate site metadata")
          end
          if socket = site.upstream
            validate_upstream_path(site, socket, require_existing: false)
          end
          sites << site
        end
        sites
      end

      private def reject_unknown_keys(object : Hash(String, JSON::Any), allowed : Array(String)) : Nil
        object.each_key do |key|
          raise Error.new("registry contains unsupported metadata") unless allowed.includes?(key)
        end
      end

      private def write_unlocked(sites : Array(Site)) : Nil
        temporary_file : File? = nil
        temporary = ""
        begin
          # File.tempfile uses O_EXCL, so even a hostile pre-existing name
          # cannot redirect this replacement. The file remains beside the
          # registry, making rename a single-filesystem atomic replacement.
          temporary_file = File.tempfile(".registry", ".tmp", dir: @paths.root)
          temporary = temporary_file.not_nil!.path
          temporary_file.not_nil!.chmod(StateSecurity::FILE_MODE)
          JSON.build(temporary_file.not_nil!) do |json|
            json.object do
              json.field "version", VERSION
              json.field "sites" do
                json.array do
                  sites.each { |site| site.to_json(json) }
                end
              end
            end
          end
          temporary_file.not_nil!.flush
          temporary_file.not_nil!.fsync
          temporary_file.not_nil!.close
          File.rename(temporary, @registry_file)
          File.chmod(@registry_file, StateSecurity::FILE_MODE)
        ensure
          temporary_file.try do |file|
            file.close unless file.closed?
          end
          File.delete(temporary) if !temporary.empty? && File.info?(temporary, follow_symlinks: false)
        end
      rescue ex : File::Error
        raise Error.new("unable to atomically update registry")
      end

      private def validate_upstream_path(site : Site, socket : String, *, require_existing : Bool) : String
        StateSecurity.reject_controls!(socket, "upstream socket")
        path = Path[socket]
        raise Error.new("upstream socket must be absolute") unless path.absolute?
        raw_parts = socket.split('/')
        if raw_parts.any? { |part| part == "." || part == ".." }
          raise Error.new("upstream socket traversal is forbidden")
        end
        site_runtime = @paths.site_run_dir(site.id)
        candidate = path.normalize.to_s
        prefix = "#{site_runtime}/"
        unless candidate.starts_with?(prefix) && File.dirname(candidate) == site_runtime
          raise Error.new("upstream socket must be inside the site's private runtime directory")
        end
        basename = File.basename(candidate)
        raise Error.new("upstream socket name is invalid") if basename.empty? || basename == "." || basename == ".."
        unless require_existing
          if File.info?(candidate, follow_symlinks: false)
            StateSecurity.validate_socket_entry(candidate, require_socket: true)
          end
          return candidate
        end
        StateSecurity.validate_socket_entry(candidate, require_socket: true)
        candidate
      end
    end
  end
end
