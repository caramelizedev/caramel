require "digest/sha256"
require "c/unistd"

module Caramel
  module Latte
    # Filesystem policy shared by the Latte state primitives. Managed state is
    # private to the current Unix user and is never reached through a symlink.
    module StateSecurity
      DIR_MODE  = 0o700
      FILE_MODE = 0o600

      def self.current_uid : Int64
        LibC.getuid.to_i64
      end

      def self.reject_controls!(value : String, label : String) : Nil
        value.each_byte do |byte|
          if byte < 0x20 || byte == 0x7f
            raise ArgumentError.new("#{label} contains a control character")
          end
        end
      end

      # Creates each missing component independently. This keeps a newly
      # created component at 0700 and lets us reject symlinks before following
      # them. Existing system parents are only checked for symlinks; the final
      # managed directory is owned and normalized below.
      def self.ensure_owned_directory(path : String) : String
        path = Path[path].expand(home: Path.home).normalize.to_s
        reject_controls!(path, "state path")

        current = path.starts_with?('/') ? "/" : ""
        components = path.split('/').reject(&.empty?)
        components.each do |component|
          current = if current == "/"
                      "/#{component}"
                    elsif current.empty?
                      component
                    else
                      "#{current}/#{component}"
                    end

          info = File.info?(current, follow_symlinks: false)
          if info.nil?
            begin
              Dir.mkdir(current, DIR_MODE)
            rescue ex : File::Error
              # A concurrent creator is safe only if it produced a real
              # directory; anything else is treated as a path attack.
              info = File.info?(current, follow_symlinks: false)
              raise ex unless info
            end
            info = File.info?(current, follow_symlinks: false)
            raise ArgumentError.new("state path contains a symlink") if info.nil? || info.symlink?
            raise ArgumentError.new("state path is not a directory") unless info.directory?
            unless info.owner_id.to_i64? == current_uid
              raise ArgumentError.new("state directory has foreign ownership")
            end
            File.chmod(current, DIR_MODE)
            info = File.info?(current, follow_symlinks: false)
          end

          raise ArgumentError.new("state path contains a symlink") if info.not_nil!.symlink?
        end

        info = File.info?(path, follow_symlinks: false)
        raise ArgumentError.new("state directory does not exist") unless info
        raise ArgumentError.new("state path contains a symlink") if info.symlink?
        raise ArgumentError.new("state path is not a directory") unless info.directory?
        unless info.owner_id.to_i64? == current_uid
          raise ArgumentError.new("state directory has foreign ownership")
        end
        File.chmod(path, DIR_MODE) if info.permissions.value != DIR_MODE
        path
      end

      # Resolve an existing parent before creating a managed path. This keeps
      # /var -> /private/var style platform aliases out of the stored path
      # while still rejecting a symlink at the managed root itself.
      def self.canonical_creation_path(path : String) : String
        path = Path[path].expand(home: Path.home).normalize.to_s
        reject_controls!(path, "state path")
        if info = File.info?(path, follow_symlinks: false)
          raise ArgumentError.new("state path contains a symlink") if info.symlink?
          return File.realpath(path)
        end

        missing = [] of String
        cursor = path
        until info = File.info?(cursor, follow_symlinks: false)
          parent = File.dirname(cursor)
          raise ArgumentError.new("state path has no existing parent") if parent == cursor
          missing << File.basename(cursor)
          cursor = parent
        end
        raise ArgumentError.new("state path contains a symlink") if info.symlink?
        canonical = File.realpath(cursor)
        missing.reverse_each { |component| canonical = File.join(canonical, component) }
        canonical
      end

      def self.validate_owned_directory(path : String) : Nil
        info = File.info?(path, follow_symlinks: false)
        raise ArgumentError.new("managed directory is missing") unless info
        raise ArgumentError.new("managed directory contains a symlink") if info.symlink?
        raise ArgumentError.new("managed path is not a directory") unless info.directory?
        unless info.owner_id.to_i64? == current_uid
          raise ArgumentError.new("managed directory has foreign ownership")
        end
        unless info.permissions.value == DIR_MODE
          raise ArgumentError.new("managed directory must be mode 0700")
        end
      end

      def self.validate_socket_entry(path : String, *, require_socket = false) : File::Info
        reject_controls!(path, "socket path")
        info = File.info?(path, follow_symlinks: false)
        raise ArgumentError.new("socket path does not exist") unless info
        raise ArgumentError.new("socket path contains a symlink") if info.symlink?
        unless info.owner_id.to_i64? == current_uid
          raise ArgumentError.new("socket path has foreign ownership")
        end
        raise ArgumentError.new("upstream is not a Unix socket") if require_socket && !info.type.socket?
        if (info.permissions.value & 0o077) != 0
          raise ArgumentError.new("socket path must be private")
        end
        info
      end

      def self.runtime_root(canonical_root : String) : String
        digest = Digest::SHA256.hexdigest(canonical_root)[0, 12]
        "/private/tmp/caramel-#{current_uid}-#{digest}"
      end

      def self.valid_site_id?(id : String) : Bool
        !!(id =~ /\A[0-9a-f]{16}\z/)
      end
    end

    # Durable Latte state lives under the user's Application Support folder.
    # Unix-domain socket paths are shorter than macOS's 104-byte limit by using
    # a stable per-user runtime directory in /private/tmp. The durable root is
    # still the source of truth; run_dir is intentionally ephemeral runtime
    # state and may be recreated after a reboot.
    class Paths
      DEFAULT_ROOT = "~/Library/Application Support/Caramel"

      getter root : String

      def initialize(root : String? = nil)
        selected = root || ENV["CARAMEL_HOME"]? || DEFAULT_ROOT
        if selected.strip.empty?
          raise ArgumentError.new("state root must not be empty")
        end
        StateSecurity.reject_controls!(selected, "state root")
        expanded = StateSecurity.canonical_creation_path(Path[selected].expand(home: Path.home).normalize.to_s)
        @root = StateSecurity.ensure_owned_directory(expanded)
        @root = File.realpath(@root)
        runtime = StateSecurity.canonical_creation_path(StateSecurity.runtime_root(@root))
        @run_dir = StateSecurity.ensure_owned_directory(runtime)
      end

      def run_dir : String
        StateSecurity.ensure_owned_directory(@run_dir)
      end

      def control_socket : String
        socket_path(File.join(run_dir, "latte.sock"))
      end

      def site_run_dir(id : String) : String
        unless StateSecurity.valid_site_id?(id)
          raise ArgumentError.new("invalid site id")
        end
        sites = StateSecurity.ensure_owned_directory(File.join(run_dir, "sites"))
        StateSecurity.ensure_owned_directory(File.join(sites, id))
      end

      def postgres_data : String
        services = StateSecurity.ensure_owned_directory(File.join(root, "services"))
        postgres = StateSecurity.ensure_owned_directory(File.join(services, "postgres"))
        major = StateSecurity.ensure_owned_directory(File.join(postgres, "18"))
        StateSecurity.ensure_owned_directory(File.join(major, "data"))
      end

      def postgres_socket_dir : String
        StateSecurity.ensure_owned_directory(File.join(run_dir, "postgres"))
      end

      def secrets_dir : String
        StateSecurity.ensure_owned_directory(File.join(root, "secrets"))
      end

      def logs_dir : String
        StateSecurity.ensure_owned_directory(File.join(root, "logs"))
      end

      def dns_dir : String
        services = StateSecurity.ensure_owned_directory(File.join(root, "services"))
        StateSecurity.ensure_owned_directory(File.join(services, "dns"))
      end

      def caddy_dir : String
        services = StateSecurity.ensure_owned_directory(File.join(root, "services"))
        StateSecurity.ensure_owned_directory(File.join(services, "caddy"))
      end

      private def socket_path(path : String) : String
        StateSecurity.reject_controls!(path, "socket path")
        if info = File.info?(path, follow_symlinks: false)
          raise ArgumentError.new("socket path contains a symlink") if info.symlink?
          raise ArgumentError.new("socket path has foreign ownership") unless info.owner_id.to_i64? == StateSecurity.current_uid
        end
        path
      end
    end
  end
end
