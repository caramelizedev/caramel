require "digest/sha256"
require "c/unistd"
require "system/user"

module Caramel
  module Latte
    # An error whose message is safe to show the user: Latte's CLI and control
    # API answer with it (*status* over HTTP). Raised anywhere in Latte, so it
    # lives in its lowest-level file.
    class PublicError < Exception
      getter code : String
      getter status : Int32

      def initialize(@code : String, message : String, @status : Int32 = 503)
        super(message)
      end
    end

    # Filesystem policy shared by the Latte state primitives. Managed state is
    # private to the current Unix user and is never reached through a symlink.
    module StateSecurity
      DIR_MODE  = 0o700
      FILE_MODE = 0o600

      def self.current_uid : Int64
        LibC.getuid.to_i64
      end

      # A regular file owned by the current user. Pass the info of an lstat
      # (`follow_symlinks: false`): a symlink then reports its own type, so it
      # is never a regular file.
      def self.owned_file?(info : File::Info) : Bool
        info.file? && info.owner_id.to_i64? == current_uid
      end

      # An owned file with exactly *mode*, as Latte writes its private state.
      def self.private_file?(info : File::Info, mode : Int32 = FILE_MODE) : Bool
        owned_file?(info) && info.permissions.value == mode
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
      # ameba:disable Metrics/CyclomaticComplexity -- verifies each path component before using it
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

          raise ArgumentError.new("state path contains a symlink") if info.nil? || info.symlink?
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
        if require_socket && !info.type.socket?
          raise ArgumentError.new("upstream is not a Unix socket")
        end
        if (info.permissions.value & 0o077) != 0
          raise ArgumentError.new("socket path must be private")
        end
        info
      end

      # The home directory of the current Unix user from the passwd database,
      # not $HOME, which fixtures and launchers fake.
      def self.user_home : String
        System::User.find_by(id: LibC.getuid.to_s).home_directory
      end

      # The ephemeral runtime directory for the state root *canonical_root*:
      # `<home>/Library/Caches/Caramel/<8 hex of its SHA-256>`. Under the user's
      # home, another user cannot pre-create it, which /private/tmp allowed.
      def self.runtime_root(canonical_root : String, home : String = user_home) : String
        digest = Digest::SHA256.hexdigest(canonical_root)[0, 8]
        File.join(home, "Library", "Caches", "Caramel", digest)
      end

      def self.valid_site_id?(id : String) : Bool
        !!(id =~ /\A[0-9a-f]{16}\z/)
      end
    end

    # Durable Latte state lives under the user's Application Support folder.
    # Unix-domain socket paths stay under macOS's 104-byte sun_path by using a
    # short per-user runtime directory in ~/Library/Caches/Caramel, named by a
    # digest of the durable root. The durable root is still the source of
    # truth; run_dir is intentionally ephemeral runtime state and may be
    # recreated after a reboot or a cache purge.
    class Paths
      DEFAULT_ROOT = "~/Library/Application Support/Caramel"
      # The detached daemon's output, in logs_dir.
      DAEMON_LOG = "latte.log"
      # macOS sun_path holds 104 bytes including the terminator.
      SOCKET_PATH_LIMIT = 103
      # The longest socket under run_dir: a site's `app-xxxxxxxx.ops.sock`.
      LONGEST_SOCKET = "/sites/0123456789abcdef/app-xxxxxxxx.ops.sock"

      getter root : String

      # *home* names the runtime directory's parent, by default the current
      # user's passwd home.
      def initialize(root : String? = nil, home : String = StateSecurity.user_home)
        selected = root || ENV["CARAMEL_HOME"]? || DEFAULT_ROOT
        if selected.strip.empty?
          raise ArgumentError.new("state root must not be empty")
        end
        StateSecurity.reject_controls!(selected, "state root")
        expanded = Path[selected].expand(home: Path.home).normalize.to_s
        canonical = StateSecurity.canonical_creation_path(expanded)
        @root = StateSecurity.ensure_owned_directory(canonical)
        @root = File.realpath(@root)
        runtime = StateSecurity.canonical_creation_path(StateSecurity.runtime_root(@root, home))
        longest = runtime.bytesize + LONGEST_SOCKET.bytesize
        if longest > SOCKET_PATH_LIMIT
          raise PublicError.new("runtime_path_too_long",
            "Latte's runtime directory #{runtime} makes a socket path of #{longest} bytes; " \
            "macOS allows #{SOCKET_PATH_LIMIT}")
        end
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

      # Each PostgreSQL major keeps its own cluster in
      # services/postgres/<major>/data, as Postgres.app does, so a major
      # upgrade never starts on another major's files.
      def postgres_data(major : Int32) : String
        directory = StateSecurity.ensure_owned_directory(File.join(postgres_root, major.to_s))
        StateSecurity.ensure_owned_directory(File.join(directory, "data"))
      end

      def postgres_root : String
        services = StateSecurity.ensure_owned_directory(File.join(root, "services"))
        StateSecurity.ensure_owned_directory(File.join(services, "postgres"))
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

      # A site's log directory: `app.log`, `compiler.log`, `events.jsonl` and Caddy's
      # `access.log` sit together here. Frappé's `site_log_directory` is the same path.
      def site_log_dir(id : String) : String
        unless StateSecurity.valid_site_id?(id)
          raise ArgumentError.new("invalid site id")
        end
        sites = StateSecurity.ensure_owned_directory(File.join(logs_dir, "sites"))
        StateSecurity.ensure_owned_directory(File.join(sites, id))
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
          unless info.owner_id.to_i64? == StateSecurity.current_uid
            raise ArgumentError.new("socket path has foreign ownership")
          end
        end
        path
      end
    end
  end
end
