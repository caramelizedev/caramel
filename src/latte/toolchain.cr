require "file_utils"
require "./process"

module Caramel::Latte
  # Explicit, versioned paths for Latte's native tools. No tool lookup goes
  # through PATH: this prevents an unrelated Herd/Homebrew installation from
  # becoming the owner of a managed service.
  class Toolchain
    POSTGRES_VERSION = "18.6"
    POSTGRES_MAJOR   = 18
    CADDY_VERSION    = "2.11.4"
    COREDNS_VERSION  = "1.14.7"
    OPENSSL_VERSION  = "3.6.4"

    class Unavailable < Exception
    end

    class VersionMismatch < Exception
      getter expected : Int32
      getter actual : Int32?
      getter expected_version : String?
      getter actual_version : String?

      def initialize(@expected : Int32, @actual : Int32?, @expected_version : String? = nil, @actual_version : String? = nil)
        detail = if @actual_version
                   "found PostgreSQL #{@actual_version}"
                 elsif @actual
                   "found major #{@actual}"
                 else
                   "version could not be determined"
                 end
        required = @expected_version || "major #{@expected}"
        super("managed PostgreSQL #{required} is required; #{detail}")
      end
    end

    getter root : String

    def initialize(root : String? = nil)
      @root = ""
      selected = root || ENV["CARAMEL_TOOLCHAIN_ROOT"]?
      raise Unavailable.new("CARAMEL_TOOLCHAIN_ROOT is required for managed tools") unless selected
      begin
        info = File.info(selected.not_nil!, follow_symlinks: false)
        raise Unavailable.new("toolchain root must not be a symlink") if info.symlink?
        raise Unavailable.new("toolchain root must be a directory") unless info.directory?
        raise Unavailable.new("toolchain root has foreign ownership") unless info.owner_id.to_i64? == LibC.getuid.to_i64
        raise Unavailable.new("toolchain root must be private") if (info.permissions.value & 0o077) != 0
        @root = File.realpath(selected.not_nil!)
      rescue ex : File::Error
        raise Unavailable.new("managed toolchain root is unavailable")
      end
    end

    def postgres : String
      executable("data/installs/conda-postgresql/#{POSTGRES_VERSION}/bin/postgres")
    end

    def initdb : String
      executable("data/installs/conda-postgresql/#{POSTGRES_VERSION}/bin/initdb")
    end

    def pg_ctl : String
      executable("data/installs/conda-postgresql/#{POSTGRES_VERSION}/bin/pg_ctl")
    end

    def psql : String
      executable("data/installs/conda-postgresql/#{POSTGRES_VERSION}/bin/psql")
    end

    def pg_dump : String
      executable("data/installs/conda-postgresql/#{POSTGRES_VERSION}/bin/pg_dump")
    end

    def pg_restore : String
      executable("data/installs/conda-postgresql/#{POSTGRES_VERSION}/bin/pg_restore")
    end

    def pg_config : String
      executable("data/installs/conda-postgresql/#{POSTGRES_VERSION}/bin/pg_config")
    end

    def openssl : String
      executable("data/installs/conda-openssl/#{OPENSSL_VERSION}/bin/openssl")
    end

    def caddy : String
      executable("data/installs/aqua-caddyserver-caddy/#{CADDY_VERSION}/caddy")
    end

    def coredns : String
      executable("data/installs/github-coredns-coredns/#{COREDNS_VERSION}/coredns")
    end

    def command(tool : Symbol, args : Enumerable(String) = [] of String) : Array(String)
      [executable_for(tool), *args.to_a]
    end

    def run(
      tool : Symbol,
      args : Enumerable(String) = [] of String,
      *,
      input : String? = nil,
      env : Hash(String, String?)? = nil,
      timeout : Time::Span = 30.seconds,
      output_limit : Int32 = ProcessRunner::MAX_OUTPUT_BYTES,
    ) : ProcessResult
      ProcessRunner.run(command(tool, args), input: input, env: environment(env), timeout: timeout, output_limit: output_limit)
    end

    def postgres_major : Int32
      major_of_version(postgres_version)
    rescue
      raise VersionMismatch.new(POSTGRES_MAJOR, nil, POSTGRES_VERSION, nil)
    end

    def postgres_version : String
      result = ProcessRunner.run([postgres, "--version"], env: environment, timeout: 5.seconds, output_limit: 4 * 1024)
      actual = parse_version("#{result.stdout}\n#{result.stderr}") rescue nil
      raise VersionMismatch.new(POSTGRES_MAJOR, nil, POSTGRES_VERSION, nil) unless result.success? && actual
      actual.not_nil!
    end

    def verify_postgres_version!(expected : String = POSTGRES_VERSION) : String
      result = ProcessRunner.run([postgres, "--version"], env: environment, timeout: 5.seconds, output_limit: 4 * 1024)
      actual = parse_version("#{result.stdout}\n#{result.stderr}") rescue nil
      unless result.success? && actual == expected
        actual_major = actual.try { |value| major_of_version(value) }
        raise VersionMismatch.new(POSTGRES_MAJOR, actual_major, expected, actual)
      end
      actual.not_nil!
    end

    def verify_postgres_major!(expected : Int32 = POSTGRES_MAJOR) : Int32
      actual_version = verify_postgres_version!(POSTGRES_VERSION)
      actual = parse_major(actual_version)
      raise VersionMismatch.new(expected, actual, "#{expected}.x", actual_version) unless actual == expected
      actual
    end

    def environment(extra : Hash(String, String?)? = nil) : Hash(String, String?)
      values = {} of String => String?
      # The child gets only the isolated provider's helper directory and the
      # platform base utilities. The selected executable is still absolute.
      values["PATH"] = "#{File.join(@root, "bin")}:/usr/bin:/bin"
      values["CARAMEL_TOOLCHAIN_ROOT"] = @root
      values["LC_ALL"] = "C"
      %w(PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE PGSERVICE PGOPTIONS PGPASSFILE).each do |key|
        values[key] = nil
      end
      if extra
        extra.each { |key, value| values[key] = value }
      end
      values
    end

    private def executable_for(tool : Symbol) : String
      case tool
      when :postgres   then postgres
      when :initdb     then initdb
      when :pg_ctl     then pg_ctl
      when :psql       then psql
      when :pg_dump    then pg_dump
      when :pg_restore then pg_restore
      when :pg_config  then pg_config
      when :openssl    then openssl
      when :caddy      then caddy
      when :coredns    then coredns
      else
        raise ArgumentError.new("unknown managed tool #{tool}")
      end
    end

    private def executable(relative : String) : String
      path = File.join(@root, relative)
      begin
        info = File.info(path, follow_symlinks: false)
        raise Unavailable.new("managed executable is a symlink") if info.symlink?
        raise Unavailable.new("managed executable is not a regular file") unless info.file?
        raise Unavailable.new("managed executable has foreign ownership") unless info.owner_id.to_i64? == LibC.getuid.to_i64
        if (info.permissions.value & 0o022) != 0
          begin
            # The selected provider root is explicitly owned by this user.
            # Normalize only its executable mode so later launches satisfy the
            # same private-file check; no global PATH or unrelated files are
            # changed.
            File.chmod(path, info.permissions.value & ~0o022)
            info = File.info(path, follow_symlinks: false)
          rescue
            raise Unavailable.new("managed executable is writable by another user")
          end
        end
        raise Unavailable.new("managed executable is writable by another user") if (info.permissions.value & 0o022) != 0
        raise Unavailable.new("managed executable is not executable") if (info.permissions.value & 0o111) == 0
        # Some package providers publish 0775 binaries. They are still safe
        # under Latte's boundary when the provider root itself is owner-only;
        # no other user can traverse into that root to modify or execute the
        # binary. The private-root check is performed during initialization.
        root_info = File.info(@root, follow_symlinks: false)
        raise Unavailable.new("toolchain root must remain private") if root_info.owner_id.to_i64? != LibC.getuid.to_i64 || (root_info.permissions.value & 0o077) != 0
      rescue ex : File::Error
        raise Unavailable.new("managed executable is unavailable: #{relative}")
      end
      path
    end

    private def parse_major(output : String) : Int32
      major_of_version(parse_version(output))
    end

    private def major_of_version(version : String) : Int32
      version.split('.').first.to_i
    end

    private def parse_version(output : String) : String
      match = output.match(/PostgreSQL\)?\s+(\d+(?:\.\d+)+)/)
      raise ArgumentError.new("unrecognized PostgreSQL version") unless match
      match[1]
    end
  end
end
